use pgrx::prelude::*;
use pgrx::bgworkers::*;
use serde::{Deserialize, Serialize};
use uuid::Uuid;
use std::time::Duration;
use std::sync::Arc;

// Duroxide imports
use duroxide::{
    ActivityContext, OrchestrationContext, OrchestrationRegistry,
    runtime::{self, registry::ActivityRegistry},
    Client,
};

::pgrx::pg_module_magic!(name, version);

// ============================================================================
// Duroxide Configuration
// ============================================================================

/// Path to the shared SQLite database for duroxide.
/// This is used by both the background worker and client functions.
fn duroxide_db_path() -> String {
    // Use a path that's accessible by the background worker
    // Using the user's home directory is more reliable than /tmp
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    format!("{}/pg_durable_duroxide.db", home)
}

/// Connection string for the duroxide SQLite store
/// Note: SqliteProvider expects just a file path (not sqlite:// URI)
fn duroxide_connection_string() -> String {
    duroxide_db_path()
}

// ============================================================================
// Background Worker - Duroxide Runtime
// ============================================================================

#[pg_guard]
pub extern "C-unwind" fn _PG_init() {
    // Register the duroxide background worker
    BackgroundWorkerBuilder::new("pg_durable_duroxide")
        .set_function("duroxide_worker_main")
        .set_library("pg_durable_ext")
        .set_argument(0i32.into_datum())
        .enable_spi_access()
        .set_start_time(BgWorkerStartTime::RecoveryFinished)
        .set_restart_time(Some(Duration::from_secs(5)))
        .load();
}

/// Main duroxide background worker - runs the duroxide runtime continuously
#[pg_guard]
#[no_mangle]
pub extern "C-unwind" fn duroxide_worker_main(_arg: pg_sys::Datum) {
    BackgroundWorker::attach_signal_handlers(SignalWakeFlags::SIGHUP | SignalWakeFlags::SIGTERM);
    
    log!("pg_durable: duroxide background worker starting...");
    
    // Create tokio runtime for async duroxide
    let rt = match tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build() 
    {
        Ok(rt) => rt,
        Err(e) => {
            log!("pg_durable: failed to create tokio runtime: {}", e);
            return;
        }
    };
    
    // Run duroxide in the tokio runtime
    rt.block_on(async {
        run_duroxide_runtime().await;
    });
    
    log!("pg_durable: duroxide background worker terminated");
}

/// Run the duroxide runtime - this is the main async loop
async fn run_duroxide_runtime() {
    log!("pg_durable: initializing duroxide runtime with SQLite store...");
    
    // Create file-based SQLite store (shared with client)
    let db_path = duroxide_connection_string();
    let store = match duroxide::providers::sqlite::SqliteProvider::new(&db_path, None).await {
        Ok(s) => Arc::new(s),
        Err(e) => {
            log!("pg_durable: failed to create SQLite store at {}: {}", db_path, e);
            return;
        }
    };
    
    log!("pg_durable: SQLite store created at {}", duroxide_db_path());
    
    // Register activities
    let activities = ActivityRegistry::builder()
        // Simple greeting activity
        .register("Greet", |_ctx: ActivityContext, input: String| async move {
            Ok(format!("Hello, {}!", input))
        })
        // SQL execution activity (placeholder for future)
        .register("ExecuteSQL", |ctx: ActivityContext, query: String| async move {
            ctx.trace_info(format!("Would execute SQL: {}", query));
            // TODO: Actually execute SQL via a connection
            Ok(format!("SQL executed: {}", query))
        })
        .build();
    
    // Register orchestrations
    let orchestrations = OrchestrationRegistry::builder()
        .register("HelloWorld", |ctx: OrchestrationContext, input: String| async move {
            ctx.trace_info("Starting HelloWorld orchestration");
            let greeting = ctx.schedule_activity("Greet", input)
                .into_activity()
                .await?;
            ctx.trace_info(format!("Completed with: {}", greeting));
            Ok(greeting)
        })
        .build();
    
    // Start the duroxide runtime
    let _runtime = runtime::Runtime::start_with_store(
        store.clone(),
        Arc::new(activities),
        orchestrations
    ).await;
    
    log!("pg_durable: duroxide runtime started, processing orchestrations...");
    
    // Keep running until signaled to stop
    // The duroxide runtime runs its own dispatcher loops internally
    loop {
        // Check for shutdown signal every second
        tokio::time::sleep(Duration::from_secs(1)).await;
        
        // We can't easily check BackgroundWorker signals from async context,
        // so we just run indefinitely. PostgreSQL will kill us on shutdown.
    }
    
    // This won't be reached, but for completeness:
    // runtime.shutdown(None).await;
}

/// Process any pending workflow instances
fn process_pending_workflows() {
    // Find pending instances
    let result = Spi::connect(|client| {
        let query = "SELECT id::text, root_node::text FROM durable.instances WHERE status = 'pending' LIMIT 10";
        
        let mut pending = Vec::new();
        
        if let Ok(table) = client.select(query, None, &[]) {
            for row in table {
                let id: Option<String> = row.get(1).ok().flatten();
                let root_node: Option<String> = row.get(2).ok().flatten();
                if let (Some(id), Some(root)) = (id, root_node) {
                    pending.push((id, root));
                }
            }
        }
        
        pending
    });
    
    // Execute each pending workflow
    for (instance_id, root_node) in result {
        log!("Processing workflow instance: {}", instance_id);
        execute_workflow(&instance_id, &root_node);
    }
}

/// Execute a workflow starting from the root node
fn execute_workflow(instance_id: &str, root_node_id: &str) {
    // Update instance to 'running'
    let update_sql = format!(
        "UPDATE durable.instances SET status = 'running', updated_at = now() WHERE id = '{}'::uuid",
        instance_id
    );
    if let Err(e) = Spi::run(&update_sql) {
        log!("Failed to update instance status: {:?}", e);
        return;
    }
    
    // Execute the node tree recursively
    match execute_node(root_node_id) {
        Ok(result) => {
            // Mark instance as completed
            let complete_sql = format!(
                "UPDATE durable.instances SET status = 'completed', completed_at = now(), updated_at = now() WHERE id = '{}'::uuid",
                instance_id
            );
            let _ = Spi::run(&complete_sql);
            log!("Workflow {} completed with result: {:?}", instance_id, result);
        }
        Err(err) => {
            // Mark instance as failed
            let err_escaped = err.replace('\'', "''");
            let fail_sql = format!(
                "UPDATE durable.instances SET status = 'failed', updated_at = now() WHERE id = '{}'::uuid",
                instance_id
            );
            let _ = Spi::run(&fail_sql);
            log!("Workflow {} failed: {}", instance_id, err_escaped);
        }
    }
}

/// Execute a single node and return its result
fn execute_node(node_id: &str) -> Result<Option<String>, String> {
    // Fetch node info
    let node_sql = format!(
        "SELECT node_type, query, left_node::text, right_node::text, result_name, status 
         FROM durable.nodes WHERE id = '{}'::uuid",
        node_id
    );
    
    let node_info = Spi::connect(|client| {
        if let Ok(table) = client.select(&node_sql, None, &[]) {
            for row in table {
                let node_type: Option<String> = row.get(1).ok().flatten();
                let query: Option<String> = row.get(2).ok().flatten();
                let left_node: Option<String> = row.get(3).ok().flatten();
                let right_node: Option<String> = row.get(4).ok().flatten();
                let result_name: Option<String> = row.get(5).ok().flatten();
                let status: Option<String> = row.get(6).ok().flatten();
                return Some((node_type, query, left_node, right_node, result_name, status));
            }
        }
        None
    });
    
    let (node_type, query, left_node, right_node, _result_name, status) = 
        node_info.ok_or_else(|| format!("Node {} not found", node_id))?;
    
    let node_type = node_type.ok_or_else(|| "Node has no type".to_string())?;
    
    // Skip if already completed
    if status.as_deref() == Some("completed") {
        // Return cached result
        let result_sql = format!(
            "SELECT result::text FROM durable.nodes WHERE id = '{}'::uuid",
            node_id
        );
        return Ok(Spi::get_one::<String>(&result_sql).unwrap_or(None));
    }
    
    // Mark node as running
    let running_sql = format!(
        "UPDATE durable.nodes SET status = 'running', updated_at = now() WHERE id = '{}'::uuid",
        node_id
    );
    let _ = Spi::run(&running_sql);
    
    // Execute based on node type
    let result = match node_type.as_str() {
        "SQL" => {
            let q = query.ok_or_else(|| "SQL node has no query".to_string())?;
            execute_sql_node(node_id, &q)
        }
        "THEN" => {
            let left = left_node.ok_or_else(|| "THEN node has no left node".to_string())?;
            let right = right_node.ok_or_else(|| "THEN node has no right node".to_string())?;
            
            // Execute left node first
            execute_node(&left)?;
            // Then execute right node
            execute_node(&right)
        }
        other => Err(format!("Unknown node type: {}", other)),
    }?;
    
    // Mark node as completed and store result
    let result_json = result.as_ref()
        .map(|r| format!("'{}'", r.replace('\'', "''")))
        .unwrap_or_else(|| "NULL".to_string());
    
    let complete_sql = format!(
        "UPDATE durable.nodes SET status = 'completed', result = {}, updated_at = now() WHERE id = '{}'::uuid",
        result_json, node_id
    );
    let _ = Spi::run(&complete_sql);
    
    Ok(result)
}

/// Execute a SQL node and return the result as JSON
fn execute_sql_node(node_id: &str, query: &str) -> Result<Option<String>, String> {
    log!("Executing SQL node {}: {}", node_id, query);
    
    // Execute the query and capture result
    let result = Spi::connect(|client| {
        match client.select(query, None, &[]) {
            Ok(table) => {
                // Convert first row to JSON-ish format
                let mut rows = Vec::new();
                for row in table {
                    let mut cols = Vec::new();
                    // Try to get columns (simple approach for MVP)
                    for i in 1..=10 {
                        if let Ok(Some(val)) = row.get::<String>(i) {
                            cols.push(val);
                        } else if let Ok(Some(val)) = row.get::<i64>(i) {
                            cols.push(val.to_string());
                        } else if let Ok(Some(val)) = row.get::<i32>(i) {
                            cols.push(val.to_string());
                        }
                    }
                    if !cols.is_empty() {
                        rows.push(cols);
                    }
                }
                if rows.is_empty() {
                    Ok(None)
                } else {
                    // Simple JSON representation
                    Ok(Some(format!("{:?}", rows)))
                }
            }
            Err(e) => Err(format!("Query failed: {:?}", e)),
        }
    });
    
    result
}

// ============================================================================
// Duroxide Client Functions
// ============================================================================

/// Start a duroxide orchestration via the shared SQLite store.
/// The background worker will pick it up and execute it.
fn start_duroxide_orchestration(
    orchestration_name: &str, 
    instance_id: &str, 
    input: &str
) -> Result<(), String> {
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| format!("Failed to create tokio runtime: {}", e))?;
    
    rt.block_on(async {
        let db_path = duroxide_connection_string();
        let store = Arc::new(
            duroxide::providers::sqlite::SqliteProvider::new(&db_path, None)
                .await
                .map_err(|e| format!("Failed to connect to duroxide store: {}", e))?
        );
        
        let client = Client::new(store);
        client.start_orchestration(instance_id, orchestration_name, input)
            .await
            .map_err(|e| format!("Failed to start orchestration: {:?}", e))?;
        
        Ok(())
    })
}

/// Wait for a duroxide orchestration to complete and return its result.
fn wait_duroxide_orchestration(instance_id: &str, timeout_secs: u64) -> Result<String, String> {
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| format!("Failed to create tokio runtime: {}", e))?;
    
    rt.block_on(async {
        let db_path = duroxide_connection_string();
        let store = Arc::new(
            duroxide::providers::sqlite::SqliteProvider::new(&db_path, None)
                .await
                .map_err(|e| format!("Failed to connect to duroxide store: {}", e))?
        );
        
        let client = Client::new(store);
        let result = client.wait_for_orchestration(instance_id, Duration::from_secs(timeout_secs))
            .await
            .map_err(|e| format!("Failed to wait for orchestration: {:?}", e))?;
        
        match result {
            runtime::OrchestrationStatus::Completed { output } => Ok(output),
            runtime::OrchestrationStatus::Failed { details } => {
                Err(format!("Orchestration failed: {}", details.display_message()))
            }
            runtime::OrchestrationStatus::Running => {
                Err("Orchestration still running (timeout)".to_string())
            }
            runtime::OrchestrationStatus::NotFound => {
                Err("Orchestration not found".to_string())
            }
        }
    })
}

/// Get the status of a duroxide orchestration.
fn get_duroxide_status(instance_id: &str) -> Result<String, String> {
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| format!("Failed to create tokio runtime: {}", e))?;
    
    rt.block_on(async {
        let db_path = duroxide_connection_string();
        let store = Arc::new(
            duroxide::providers::sqlite::SqliteProvider::new(&db_path, None)
                .await
                .map_err(|e| format!("Failed to connect to duroxide store: {}", e))?
        );
        
        let client = Client::new(store);
        let status = client.get_orchestration_status(instance_id)
            .await
            .map_err(|e| format!("Failed to get status: {:?}", e))?;
        
        Ok(format!("{:?}", status))
    })
}

/// Declare the 'durable' schema that contains all pg_durable functions
#[pg_schema]
mod durable {}

// ============================================================================
// Schema and Table Definitions
// ============================================================================

// Create the workflow storage tables when extension is created
extension_sql!(
    r#"
-- Table to store workflow nodes (SQL steps, THEN chains, etc.)
CREATE TABLE IF NOT EXISTS durable.nodes (
    id UUID PRIMARY KEY,
    instance_id UUID,
    node_type TEXT NOT NULL,
    query TEXT,
    result_name TEXT,
    left_node UUID,
    right_node UUID,
    status TEXT DEFAULT 'pending',
    result JSONB,
    error TEXT,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

-- Table to store workflow instances
CREATE TABLE IF NOT EXISTS durable.instances (
    id UUID PRIMARY KEY,
    root_node UUID NOT NULL,
    status TEXT DEFAULT 'pending',
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now(),
    completed_at TIMESTAMPTZ
);

-- Index for finding pending instances
CREATE INDEX IF NOT EXISTS idx_instances_status ON durable.instances(status);

-- Index for finding nodes by instance
CREATE INDEX IF NOT EXISTS idx_nodes_instance ON durable.nodes(instance_id);
"#,
    name = "create_tables",
    requires = [durable]
);

// ============================================================================
// Durofut Type - Represents a workflow node reference
// ============================================================================

/// The Durofut type represents a "durable future" - a reference to a node in the workflow graph.
/// For the MVP, we serialize this as JSON and pass it as text between SQL function calls.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Durofut {
    /// Unique ID of this node
    pub node_id: String,
    /// Type of the node (SQL, THEN, etc.)
    pub node_type: String,
    /// For THEN nodes: the left (first) node ID
    #[serde(skip_serializing_if = "Option::is_none")]
    pub left_node: Option<String>,
    /// For THEN nodes: the right (second) node ID  
    #[serde(skip_serializing_if = "Option::is_none")]
    pub right_node: Option<String>,
    /// For SQL nodes: the query to execute
    #[serde(skip_serializing_if = "Option::is_none")]
    pub query: Option<String>,
    /// For AS nodes: the name to bind the result to
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result_name: Option<String>,
}

impl Durofut {
    fn to_json(&self) -> String {
        serde_json::to_string(self).expect("failed to serialize Durofut")
    }

    fn from_json(s: &str) -> Self {
        serde_json::from_str(s).expect("failed to deserialize Durofut")
    }

    /// Insert this node into the durable.nodes table
    fn insert_node(&self) {
        let query_escaped = self.query.as_ref()
            .map(|q| q.replace('\'', "''"))
            .map(|q| format!("'{}'", q))
            .unwrap_or_else(|| "NULL".to_string());
        
        let result_name_escaped = self.result_name.as_ref()
            .map(|n| format!("'{}'", n.replace('\'', "''")))
            .unwrap_or_else(|| "NULL".to_string());
        
        let left_node = self.left_node.as_ref()
            .map(|id| format!("'{}'::uuid", id))
            .unwrap_or_else(|| "NULL".to_string());
        
        let right_node = self.right_node.as_ref()
            .map(|id| format!("'{}'::uuid", id))
            .unwrap_or_else(|| "NULL".to_string());

        let sql = format!(
            r#"INSERT INTO durable.nodes (id, node_type, query, result_name, left_node, right_node)
               VALUES ('{}', '{}', {}, {}, {}, {})"#,
            self.node_id, self.node_type, query_escaped, result_name_escaped, left_node, right_node
        );
        
        Spi::run(&sql).expect("failed to insert node");
    }
}

// ============================================================================
// Public SQL Functions
// ============================================================================

/// Simple hello world function to verify extension works
#[pg_extern]
fn hello_pg_durable_ext() -> &'static str {
    "Hello, pg_durable_ext"
}

/// Creates a SQL node in the workflow graph.
/// 
/// Example: SELECT durable.sql('SELECT count(*) FROM users');
/// 
/// Returns a JSON-encoded Durofut that can be chained with ~> or passed to start().
#[pg_extern(schema = "durable")]
fn sql(query: &str) -> String {
    let durofut = Durofut {
        node_id: Uuid::new_v4().to_string(),
        node_type: "SQL".to_string(),
        left_node: None,
        right_node: None,
        query: Some(query.to_string()),
        result_name: None,
    };
    // Store the node in the database
    durofut.insert_node();
    durofut.to_json()
}

/// Chains two futures sequentially: run `a`, then run `b`.
/// 
/// Example: SELECT durable.seq(durable.sql('A'), durable.sql('B'));
/// 
/// The SQL operator ~> is syntactic sugar for this function.
#[pg_extern(name = "seq", schema = "durable")]
fn then_fn(a: &str, b: &str) -> String {
    let a_fut = Durofut::from_json(a);
    let b_fut = Durofut::from_json(b);
    
    let durofut = Durofut {
        node_id: Uuid::new_v4().to_string(),
        node_type: "THEN".to_string(),
        left_node: Some(a_fut.node_id),
        right_node: Some(b_fut.node_id),
        query: None,
        result_name: None,
    };
    // Store the THEN node in the database
    durofut.insert_node();
    durofut.to_json()
}

/// Names a future's result for later reference as $name.
/// 
/// Example: SELECT durable.as_named('users', durable.sql('SELECT count(*) FROM users'));
/// 
/// The SQL operator => is syntactic sugar for this function.
#[pg_extern(name = "as", schema = "durable")]
fn as_named(name: &str, fut: &str) -> String {
    let mut durofut = Durofut::from_json(fut);
    durofut.result_name = Some(name.to_string());
    
    // Update the node's result_name in the database
    let name_escaped = name.replace('\'', "''");
    let sql = format!(
        "UPDATE durable.nodes SET result_name = '{}' WHERE id = '{}'::uuid",
        name_escaped, durofut.node_id
    );
    Spi::run(&sql).expect("failed to update node result_name");
    
    durofut.to_json()
}

/// Starts a workflow instance and returns the instance ID.
/// 
/// Example: SELECT durable.start(durable.sql('SELECT 1') ~> durable.sql('SELECT 2'));
/// 
/// This function:
/// 1. Creates an instance in durable.instances
/// 2. Links all nodes to the instance
/// 3. Returns the instance ID for tracking
#[pg_extern(schema = "durable")]
fn start(fut: &str) -> String {
    let durofut = Durofut::from_json(fut);
    let instance_id = Uuid::new_v4().to_string();
    
    // Update all nodes in the workflow tree with this instance_id
    // This is a simple recursive update via SQL
    let update_nodes_sql = format!(
        r#"
        WITH RECURSIVE node_tree AS (
            -- Start with the root node
            SELECT id, left_node, right_node FROM durable.nodes WHERE id = '{}'::uuid
            UNION ALL
            -- Recursively find all child nodes
            SELECT n.id, n.left_node, n.right_node 
            FROM durable.nodes n
            INNER JOIN node_tree t ON n.id = t.left_node OR n.id = t.right_node
        )
        UPDATE durable.nodes SET instance_id = '{}'::uuid
        WHERE id IN (SELECT id FROM node_tree)
        "#,
        durofut.node_id, instance_id
    );
    Spi::run(&update_nodes_sql).expect("failed to update nodes with instance_id");

    // Create the instance record
    let create_instance_sql = format!(
        "INSERT INTO durable.instances (id, root_node, status) VALUES ('{}'::uuid, '{}'::uuid, 'pending')",
        instance_id, durofut.node_id
    );
    Spi::run(&create_instance_sql).expect("failed to create instance");
    
    instance_id
}

/// Get the status of a workflow instance.
/// 
/// Example: SELECT durable.status('instance-uuid');
#[pg_extern(schema = "durable")]
fn status(instance_id: &str) -> Option<String> {
    let sql = format!(
        "SELECT status FROM durable.instances WHERE id = '{}'::uuid",
        instance_id
    );
    Spi::get_one::<String>(&sql).expect("failed to get instance status")
}

/// Manually run pending workflows (for testing, or when background worker isn't available).
/// 
/// Example: SELECT durable.run();  -- runs all pending workflows
/// Example: SELECT durable.run('instance-uuid');  -- runs specific workflow
#[pg_extern(schema = "durable")]
fn run(instance_id: default!(Option<&str>, "NULL")) -> String {
    if let Some(id) = instance_id {
        // Run specific instance
        let root_sql = format!(
            "SELECT root_node::text FROM durable.instances WHERE id = '{}'::uuid AND status = 'pending'",
            id
        );
        if let Some(root_node) = Spi::get_one::<String>(&root_sql).expect("failed to get root node") {
            execute_workflow(id, &root_node);
            format!("Executed workflow {}", id)
        } else {
            format!("No pending workflow found with id {}", id)
        }
    } else {
        // Run all pending instances
        process_pending_workflows();
        "Processed all pending workflows".to_string()
    }
}

/// Get detailed result of a workflow instance.
/// 
/// Example: SELECT durable.result('instance-uuid');
#[pg_extern(schema = "durable")]
fn result(instance_id: &str) -> Option<String> {
    // Get the root node's result
    let sql = format!(
        r#"SELECT n.result::text 
           FROM durable.instances i 
           JOIN durable.nodes n ON n.id = i.root_node 
           WHERE i.id = '{}'::uuid"#,
        instance_id
    );
    Spi::get_one::<String>(&sql).expect("failed to get instance result")
}

/// A hello world function that runs a duroxide orchestration.
/// This demonstrates duroxide integration is working.
/// The orchestration runs in the background worker; this function 
/// starts it and waits for the result.
/// 
/// Example: SELECT durable.hello('World');
/// Returns: "Hello, World!" (via duroxide orchestration)
#[pg_extern(schema = "durable")]  
fn hello(name: &str) -> String {
    // Generate a unique instance ID
    let instance_id = Uuid::new_v4().to_string();
    
    // Start the HelloWorld orchestration
    if let Err(e) = start_duroxide_orchestration("HelloWorld", &instance_id, name) {
        return format!("Failed to start orchestration: {}", e);
    }
    
    // Wait for the result (up to 30 seconds)
    match wait_duroxide_orchestration(&instance_id, 30) {
        Ok(result) => result,
        Err(e) => format!("Orchestration error: {}", e),
    }
}

/// Test function to verify duroxide integration is working.
/// This starts a HelloWorld orchestration and waits for the result.
/// 
/// Example: SELECT durable.duroxide_test();
#[pg_extern(schema = "durable")]
fn duroxide_test() -> String {
    let instance_id = Uuid::new_v4().to_string();
    
    // Start the HelloWorld orchestration
    if let Err(e) = start_duroxide_orchestration("HelloWorld", &instance_id, "duroxide") {
        return format!("FAILED to start: {}", e);
    }
    
    // Wait for the result
    match wait_duroxide_orchestration(&instance_id, 30) {
        Ok(result) => format!("SUCCESS: {}", result),
        Err(e) => format!("FAILED: {}", e),
    }
}

/// Check status of a duroxide orchestration by instance ID.
/// 
/// Example: SELECT durable.orchestration_status('some-uuid-here');
#[pg_extern(schema = "durable")]
fn orchestration_status(instance_id: &str) -> String {
    match get_duroxide_status(instance_id) {
        Ok(status) => status,
        Err(e) => format!("Error: {}", e),
    }
}

// Create custom SQL operators for workflow chaining
extension_sql!(
    r#"
-- Operator ~> for sequencing: a ~> b means "run a, then run b"
CREATE OPERATOR ~> (
    FUNCTION = durable.seq,
    LEFTARG = text,
    RIGHTARG = text
);

-- Operator |=> for naming: 'name' |=> fut means "name this result as $name"
CREATE OPERATOR |=> (
    FUNCTION = durable.as,
    LEFTARG = text,
    RIGHTARG = text
);
"#,
    name = "create_operators",
    requires = [then_fn, as_named]
);

#[cfg(any(test, feature = "pg_test"))]
#[pg_schema]
mod tests {
    use pgrx::prelude::*;
    use crate::Durofut;

    #[pg_test]
    fn test_hello_pg_durable_ext() {
        assert_eq!("Hello, pg_durable_ext", crate::hello_pg_durable_ext());
    }

    #[pg_test]
    fn test_sql_creates_durofut() {
        let json = crate::sql("SELECT 1");
        let fut = Durofut::from_json(&json);
        assert_eq!(fut.node_type, "SQL");
        assert!(!fut.node_id.is_empty());
        assert_eq!(fut.query, Some("SELECT 1".to_string()));
    }

    #[pg_test]
    fn test_then_creates_durofut() {
        let a = crate::sql("SELECT 1");
        let b = crate::sql("SELECT 2");
        let then_json = crate::then_fn(&a, &b);
        let then_fut = Durofut::from_json(&then_json);
        assert_eq!(then_fut.node_type, "THEN");
        assert!(then_fut.left_node.is_some());
        assert!(then_fut.right_node.is_some());
    }

    #[pg_test]
    fn test_as_named_sets_result_name() {
        let sql_json = crate::sql("SELECT 1");
        let named_json = crate::as_named("count", &sql_json);
        let named_fut = Durofut::from_json(&named_json);
        assert_eq!(named_fut.result_name, Some("count".to_string()));
    }

    #[pg_test]
    fn test_start_returns_instance_id() {
        let fut = crate::sql("SELECT 1");
        let instance_id = crate::start(&fut);
        assert!(!instance_id.is_empty());
        // Verify it's a valid UUID
        uuid::Uuid::parse_str(&instance_id).expect("should be valid UUID");
    }
}

/// This module is required by `cargo pgrx test` invocations.
/// It must be visible at the root of your extension crate.
#[cfg(test)]
pub mod pg_test {
    pub fn setup(_options: Vec<&str>) {
        // perform one-off initialization when the pg_test framework starts
    }

    #[must_use]
    pub fn postgresql_conf_options() -> Vec<&'static str> {
        // return any postgresql.conf settings that are required for your tests
        vec![]
    }
}
