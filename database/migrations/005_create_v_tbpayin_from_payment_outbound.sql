CREATE OR REPLACE ALGORITHM=UNDEFINED SQL SECURITY INVOKER VIEW `v_tbpayin_from_payment_outbound` AS
SELECT
    UPPER(COALESCE(po.`company_id`, '')) AS `comp`,
    COALESCE(po.`eft_file_name`, '') AS `bulk`,
    COALESCE(po.`vendor_account`, '') AS `cust_code`,
    COALESCE(po.`vendor_name`, '') AS `cust_name`,
    COALESCE(po.`invoice_number`, '') AS `invoice`,
    COALESCE(po.`voucher_number`, '') AS `pv_no`,
    COALESCE(po.`purchase_order`, '') AS `po_no`,
    COALESCE(po.`effective_date`, po.`transaction_date`) AS `pay_date`,
    SUBSTRING_INDEX(COALESCE(po.`vendor_bank_account_code`, ''), '-', 1) AS `bank_code`,
    SUBSTRING_INDEX(COALESCE(po.`vendor_bank_account_code`, ''), '-', 1) AS `bank`,
    COALESCE(po.`vendor_bank_account_number`, '') AS `account`,
    COALESCE(po.`email_address`, '') AS `email`,
    COALESCE(po.`invoice_amount`, 0) AS `amount`,
    COALESCE(grp.`fee_total`, 0) AS `fee`,
    COALESCE(po.`withholding_tax_amount`, 0) AS `tax`,
    COALESCE(grp.`total_amount`, 0) AS `total`,
    CASE WHEN sent.`sent_at` IS NULL THEN '' ELSE '1' END AS `flag`,
    sent.`sent_at` AS `senddate`,
    COALESCE(grp.`tax_total`, 0) AS `tax1`,
    COALESCE(po.`description`, '') AS `detail`,
    CAST(po.`id` AS CHAR CHARACTER SET utf8) AS `recid`
FROM `payment_outbound` AS po
LEFT JOIN (
    SELECT
        UPPER(COALESCE(`company_id`, '')) AS `comp`,
        COALESCE(`eft_file_name`, '') AS `bulk`,
        COALESCE(`vendor_account`, '') AS `cust_code`,
        SUM(COALESCE(`fee`, 0)) AS `fee_total`,
        SUM(COALESCE(`withholding_tax_amount`, 0)) AS `tax_total`,
        SUM(COALESCE(`total_amount`, 0)) AS `total_amount`
    FROM `payment_outbound`
    WHERE `eft_file_name` IS NOT NULL AND `eft_file_name` <> ''
    GROUP BY
        UPPER(COALESCE(`company_id`, '')),
        COALESCE(`eft_file_name`, ''),
        COALESCE(`vendor_account`, '')
) AS grp
    ON grp.`comp` = UPPER(COALESCE(po.`company_id`, ''))
   AND grp.`bulk` = COALESCE(po.`eft_file_name`, '')
   AND grp.`cust_code` = COALESCE(po.`vendor_account`, '')
LEFT JOIN (
    SELECT `comp`, `bulk`, `cust_code`, MAX(`sent_at`) AS `sent_at`
    FROM `payment_mail_log`
    WHERE `status` = 'sent'
    GROUP BY `comp`, `bulk`, `cust_code`
) AS sent
    ON sent.`comp` = UPPER(COALESCE(po.`company_id`, ''))
   AND sent.`bulk` = COALESCE(po.`eft_file_name`, '')
   AND sent.`cust_code` = COALESCE(po.`vendor_account`, '')
WHERE po.`eft_file_name` IS NOT NULL AND po.`eft_file_name` <> '';
