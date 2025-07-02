table_claer ipv4_lpm
table_set_default ipv4_lpm drop
table_add ipv4_lpm ipv4_forward 10.0.0.1/32 => 00:00:0a:00:00:01 1
table_add ipv4_lpm ipv4_forward 10.0.0.2/32 => 00:00:0a:00:00:02 2
table_claer rule_tbl
table_set_default rule_tbl NoAction
table_add rule_tbl flow_control 10.0.0.2 => 1 1 1 10 1 1 1000000