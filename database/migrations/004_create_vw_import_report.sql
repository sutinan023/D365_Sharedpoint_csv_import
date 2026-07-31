CREATE OR REPLACE ALGORITHM=UNDEFINED SQL SECURITY INVOKER VIEW `vw_import_report` AS
SELECT
    p.`id` AS `no`, p.`bank_account_code`, p.`transaction_date`, p.`effective_date`,
    p.`cashflow`, p.`journal_batch`, p.`voucher_number`, p.`description`, p.`type`,
    p.`vendor_account` AS `account_no`, p.`vendor_name` AS `account_name`,
    p.`email_address`, p.`purchase_order` AS `order_no`, p.`invoice_number`,
    p.`vendor_bank_account_code`, p.`vendor_bank_account_number`,
    p.`bank_transaction_type`, p.`method_of_payment`, p.`invoice_amount`, p.`fee`,
    p.`withholding_tax_amount`, p.`total_amount`, 'PAYMENT_OUTBOUND' AS `source_type`
FROM `stg_payment_outbound` AS p
UNION ALL
SELECT
    r.`id` AS `no`, r.`bank_account_code`, r.`transaction_date`, r.`effective_date`,
    r.`cashflow`, r.`journal_batch`, r.`voucher_number`, r.`description`, r.`type`,
    r.`customer_account` AS `account_no`, r.`customer_name` AS `account_name`,
    r.`email_address`, r.`sales_order` AS `order_no`, r.`invoice_number`,
    r.`vendor_bank_account_code`, r.`vendor_bank_account_number`,
    r.`bank_transaction_type`, r.`method_of_payment`, r.`invoice_amount`, r.`fee`,
    r.`withholding_tax_amount`, r.`total_amount`, 'RECEIVED_OUTBOUND' AS `source_type`
FROM `stg_received_outbound` AS r;
