# Compensation & Saga Pattern

**Status:** Proposal  
**Author:** pg_durable team  
**Date:** December 2025

## Overview

Add support for saga-style compensating transactions using the `<->` operator and `df.with_undo()` function. When a step in a durable function fails, all previously successful steps run their compensation actions in reverse order.

## API

### Operator: `<->`

```sql
forward_action <-> undo_action
```

Pairs a forward action with its compensation. If the forward succeeds but a later step fails, the undo runs automatically.

### Function: `df.with_undo()`

```sql
df.with_undo(forward_action, undo_action)
```

Equivalent to the `<->` operator, useful for complex expressions.

## Operator Precedence

| Precedence | Operator | Meaning |
|------------|----------|---------|
| 1 (highest) | `<->` | Compensate with |
| 2 | `\|=>` | Bind result |
| 3 | `&` | Parallel join |
| 4 | `\|` | Race |
| 5 | `~>` | Then (sequence) |
| 6 | `?>` `!>` | If-then-else |
| 7 (lowest) | `@>` | Loop |

## Examples

### Basic Saga

```sql
df.start(
    'INSERT INTO orders (customer_id) VALUES (42) RETURNING id' 
        <-> 'DELETE FROM orders WHERE id = $order_id' 
        |=> 'order_id'
    
    ~> 'UPDATE inventory SET qty = qty - 1 WHERE sku = ''WIDGET'''
        <-> 'UPDATE inventory SET qty = qty + 1 WHERE sku = ''WIDGET'''
    
    ~> df.http('POST', '/payments/charge', '{"order": $order_id}')
        <-> df.http('POST', '/payments/refund', '{"charge": $charge_id}')
        |=> 'charge_id'
    
    ~> 'UPDATE orders SET status = ''confirmed'' WHERE id = $order_id'
);
```

### Bank Transfer

```sql
df.start(
    'UPDATE accounts SET balance = balance - 500 WHERE id = 1'
        <-> 'UPDATE accounts SET balance = balance + 500 WHERE id = 1'
    
    ~> 'UPDATE accounts SET balance = balance + 500 WHERE id = 2'
        <-> 'UPDATE accounts SET balance = balance - 500 WHERE id = 2'
    
    ~> 'INSERT INTO transfers (from_id, to_id, amount) VALUES (1, 2, 500)'
);
```

### Cross-Database with FDW

```sql
df.start(
    'INSERT INTO orders VALUES (...) RETURNING id'
        <-> 'DELETE FROM orders WHERE id = $order_id'
        |=> 'order_id'
    
    ~> 'UPDATE remote.inventory SET qty = qty - 1 WHERE sku = $sku'
        <-> 'UPDATE remote.inventory SET qty = qty + 1 WHERE sku = $sku'
    
    ~> df.http('POST', '/shipping/create', '{"order": $order_id}')
        <-> df.http('DELETE', '/shipping/$shipment_id')
        |=> 'shipment_id'
);
```

### Parallel Steps with Compensation

```sql
df.start(
    'INSERT INTO bookings...' <-> 'DELETE FROM bookings...' |=> 'booking_id'
    
    ~> (
        'UPDATE rooms SET status = ''booked'' WHERE id = 101'
            <-> 'UPDATE rooms SET status = ''available'' WHERE id = 101'
        &
        'UPDATE parking SET reserved = true WHERE spot = ''A1'''
            <-> 'UPDATE parking SET reserved = false WHERE spot = ''A1'''
    )
    
    ~> 'INSERT INTO confirmations (booking_id) VALUES ($booking_id)'
);
```

## Execution Semantics

```
Step 1: A <-> A'     -- succeeds
Step 2: B <-> B'     -- succeeds  
Step 3: C <-> C'     -- FAILS

Compensation Flow:
  1. B' executes (compensate step 2)
  2. A' executes (compensate step 1)
  3. Saga status: "compensated"
```

### Variable Availability

- The `|=>` binding applies to the forward action's result
- Bound variables are available in:
  - Subsequent forward steps
  - The undo action of the same step
  - Undo actions of earlier steps (during compensation)

```sql
'INSERT... RETURNING id' <-> 'DELETE WHERE id = $order_id' |=> 'order_id'
-- $order_id available in the DELETE (undo uses it)
```

## Implementation

### Node Type

```json
{
  "node_type": "COMPENSATED",
  "left_node": "forward_action_node_id",
  "right_node": "undo_action_node_id",
  "result_name": "optional_binding"
}
```

### Orchestration Changes

1. Track completed compensated steps in a stack
2. On failure, pop and execute undo actions in reverse order
3. New instance status: `"compensated"` for successful rollback

### DSL Changes

1. Add `<->` operator with highest precedence
2. Add `df.with_undo(forward, undo)` function
3. Auto-wrap plain SQL strings in both positions

## Future Considerations

- Partial compensation (compensate only some steps)
- Compensation timeout/retry policies
- Nested sagas
- Compensation observability in `df.explain()`

