use pgrx::prelude::*;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

::pgrx::pg_module_magic!(name, version);

/// Declare the 'durable' schema that contains all pg_durable functions
#[pg_schema]
mod durable {}

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
}

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
    durofut.to_json()
}

/// Starts a workflow instance and returns the instance ID.
/// 
/// Example: SELECT durable.start(durable.sql('SELECT 1') ~> durable.sql('SELECT 2'));
/// 
/// For the MVP, this just returns an instance ID. 
/// The full implementation will:
/// 1. Create instance in duro_instances table
/// 2. Store all nodes in duro_nodes table
/// 3. Trigger the runtime to pick up the new instance
#[pg_extern(schema = "durable")]
fn start(fut: &str) -> String {
    let _durofut = Durofut::from_json(fut);
    let instance_id = Uuid::new_v4().to_string();
    
    // TODO: Store workflow in database and trigger runtime
    // For now, just return the instance ID
    
    instance_id
}

/// A simple hello world function to demonstrate the extension.
/// This will eventually trigger a duroxide orchestration.
#[pg_extern(schema = "durable")]  
fn hello(name: &str) -> String {
    // For now, just return a greeting synchronously
    // Full implementation would:
    // 1. Start a duroxide orchestration
    // 2. Return the instance ID
    // 3. Background worker would run the orchestration
    format!("Hello, {}! (workflow would run here)", name)
}

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
