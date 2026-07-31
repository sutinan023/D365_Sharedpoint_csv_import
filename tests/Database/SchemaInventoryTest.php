<?php

use App\Database\SchemaInventory;

return [
    'schema inventory captures database object categories' => function (): void {
        $pdo = new PDO('sqlite::memory:');
        $pdo->exec("ATTACH DATABASE ':memory:' AS information_schema");
        $pdo->exec('CREATE TABLE information_schema.TABLES (TABLE_SCHEMA TEXT, TABLE_NAME TEXT, TABLE_TYPE TEXT, ENGINE TEXT, TABLE_COLLATION TEXT)');
        $pdo->exec('CREATE TABLE information_schema.COLUMNS (TABLE_SCHEMA TEXT, TABLE_NAME TEXT, ORDINAL_POSITION INTEGER, COLUMN_NAME TEXT, COLUMN_TYPE TEXT, IS_NULLABLE TEXT, COLUMN_DEFAULT TEXT, EXTRA TEXT)');
        $pdo->exec('CREATE TABLE information_schema.STATISTICS (TABLE_SCHEMA TEXT, TABLE_NAME TEXT, INDEX_NAME TEXT, NON_UNIQUE INTEGER, SEQ_IN_INDEX INTEGER, COLUMN_NAME TEXT, SUB_PART INTEGER, INDEX_TYPE TEXT)');
        $pdo->exec('CREATE TABLE information_schema.VIEWS (TABLE_SCHEMA TEXT, TABLE_NAME TEXT, VIEW_DEFINITION TEXT, CHECK_OPTION TEXT, SECURITY_TYPE TEXT)');
        $pdo->exec('CREATE TABLE information_schema.ROUTINES (ROUTINE_SCHEMA TEXT, ROUTINE_NAME TEXT, ROUTINE_TYPE TEXT, DATA_TYPE TEXT, SECURITY_TYPE TEXT, ROUTINE_DEFINITION TEXT)');
        $pdo->exec('CREATE TABLE information_schema.TRIGGERS (TRIGGER_SCHEMA TEXT, TRIGGER_NAME TEXT, EVENT_MANIPULATION TEXT, EVENT_OBJECT_TABLE TEXT, ACTION_TIMING TEXT, ACTION_STATEMENT TEXT)');
        $pdo->exec('CREATE TABLE information_schema.TABLE_CONSTRAINTS (CONSTRAINT_SCHEMA TEXT, TABLE_NAME TEXT, CONSTRAINT_NAME TEXT, CONSTRAINT_TYPE TEXT)');
        $pdo->exec('CREATE TABLE information_schema.KEY_COLUMN_USAGE (CONSTRAINT_SCHEMA TEXT, TABLE_NAME TEXT, CONSTRAINT_NAME TEXT, ORDINAL_POSITION INTEGER, COLUMN_NAME TEXT, REFERENCED_TABLE_NAME TEXT, REFERENCED_COLUMN_NAME TEXT)');
        $pdo->exec('CREATE TABLE information_schema.CHECK_CONSTRAINTS (CONSTRAINT_SCHEMA TEXT, CONSTRAINT_NAME TEXT, CHECK_CLAUSE TEXT)');
        $pdo->exec('CREATE TABLE information_schema.EVENTS (EVENT_SCHEMA TEXT, EVENT_NAME TEXT, EVENT_DEFINITION TEXT, EVENT_TYPE TEXT, EXECUTE_AT TEXT, INTERVAL_VALUE TEXT, INTERVAL_FIELD TEXT, STATUS TEXT)');

        $pdo->exec("INSERT INTO information_schema.TABLES VALUES ('D365_finance','payment_outbound','BASE TABLE','InnoDB','utf8mb4_unicode_ci')");
        $pdo->exec("INSERT INTO information_schema.COLUMNS VALUES ('D365_finance','payment_outbound',1,'id','bigint','NO',NULL,'auto_increment')");
        $pdo->exec("INSERT INTO information_schema.STATISTICS VALUES ('D365_finance','payment_outbound','PRIMARY',0,1,'id',NULL,'BTREE')");
        $pdo->exec("INSERT INTO information_schema.VIEWS VALUES ('D365_finance','v_payment','select 1','NONE','DEFINER')");
        $pdo->exec("INSERT INTO information_schema.ROUTINES VALUES ('D365_finance','refresh_report','PROCEDURE','', 'DEFINER','BEGIN SELECT 1; END')");
        $pdo->exec("INSERT INTO information_schema.TRIGGERS VALUES ('D365_finance','audit_payment','INSERT','payment_outbound','AFTER','BEGIN END')");
        $pdo->exec("INSERT INTO information_schema.TABLE_CONSTRAINTS VALUES ('D365_finance','payment_outbound','PRIMARY','PRIMARY KEY')");
        $pdo->exec("INSERT INTO information_schema.KEY_COLUMN_USAGE VALUES ('D365_finance','payment_outbound','PRIMARY',1,'id',NULL,NULL)");
        $pdo->exec("INSERT INTO information_schema.CHECK_CONSTRAINTS VALUES ('D365_finance','positive_id','id > 0')");
        $pdo->exec("INSERT INTO information_schema.EVENTS VALUES ('D365_finance','daily_refresh','CALL refresh_report()','RECURRING',NULL,'1','DAY','ENABLED')");

        $inventory = (new SchemaInventory($pdo))->collect('D365_finance');
        assert($inventory['schema'] === 'D365_finance');
        assert($inventory['tables'][0]['TABLE_NAME'] === 'payment_outbound');
        assert($inventory['columns'][0]['COLUMN_NAME'] === 'id');
        assert($inventory['indexes'][0]['INDEX_NAME'] === 'PRIMARY');
        assert($inventory['views'][0]['TABLE_NAME'] === 'v_payment');
        assert($inventory['routines'][0]['ROUTINE_NAME'] === 'refresh_report');
        assert($inventory['triggers'][0]['TRIGGER_NAME'] === 'audit_payment');
        assert($inventory['constraints'][0]['CONSTRAINT_NAME'] === 'PRIMARY');
        assert($inventory['check_constraints'][0]['CONSTRAINT_NAME'] === 'positive_id');
        assert($inventory['events'][0]['EVENT_NAME'] === 'daily_refresh');
    },
];
