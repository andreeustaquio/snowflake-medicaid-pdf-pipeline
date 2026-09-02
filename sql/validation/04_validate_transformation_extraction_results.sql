/*
Purpose:
Validate the transformation logic applied to raw AI_EXTRACT results before loading the transformed data into the standardized fee schedule table.

This script focuses on:
- Inspecting raw extracted values.
- Validating cleaning logic.
- Checking expected NULL conversions.
- Verifying parallel array alignment.
- Confirming the expected number of extracted procedure rows.

Important:
This script is intended for testing and validation purposes only.

Run these queries after the full document has been extracted and the raw
extraction results have been stored in RAW_EXTRACTION_RESULTS.

Session prerequisites:
- Set DATABASE, SCHEMA, and WAREHOUSE before running.

Example:
USE DATABASE <DB_NAME>;
USE SCHEMA <SCHEMA_NAME>;
USE WAREHOUSE <WAREHOUSE_NAME>;
*/

SET DOCUMENT_ID = 1;
SET RUN_STATUS = 'SUCCESS';

/*
1. RAW EXTRACTION INSPECTION
*/

-- Inspect the raw modifier arrays for a specific document.
SELECT
    PAGE_NUMBER,
    RAW_EXTRACTION_RESPONSE:response:fee_schedule:modifier AS RAW_MODIFIERS
FROM RAW_EXTRACTION_RESULTS
WHERE DOCUMENT_ID = $DOCUMENT_ID
ORDER BY PAGE_NUMBER;


-- Count extracted procedure rows for a specific document.
SELECT
    r.DOCUMENT_ID,
    COUNT(*) AS RAW_ROW_COUNT
FROM RAW_EXTRACTION_RESULTS AS r,
LATERAL FLATTEN(
    input => r.RAW_EXTRACTION_RESPONSE:response:fee_schedule:code
) AS code
WHERE r.DOCUMENT_ID = $DOCUMENT_ID
  AND r.RUN_STATUS = $RUN_STATUS
GROUP BY r.DOCUMENT_ID;


/*
 2. ARRAY ALIGNMENT VALIDATION
*/

-- Verify that parallel arrays have compatible lengths for a specific document.
-- Extend this check to other fee_schedule arrays as additional fields are added.
SELECT
    DOCUMENT_ID,
    PAGE_NUMBER,
    ARRAY_SIZE(
        RAW_EXTRACTION_RESPONSE:response:fee_schedule:code
    ) AS CODE_COUNT,
    ARRAY_SIZE(
        RAW_EXTRACTION_RESPONSE:response:fee_schedule:modifier
    ) AS MODIFIER_COUNT
FROM RAW_EXTRACTION_RESULTS
WHERE DOCUMENT_ID = $DOCUMENT_ID
  AND RUN_STATUS = $RUN_STATUS
ORDER BY PAGE_NUMBER;


/*
3. PROCEDURE CODE CLEANING VALIDATION
*/

-- Compare raw procedure codes with the expected cleaned values.
SELECT
    r.PAGE_NUMBER,
    code.index AS ROW_INDEX,
    code.value::VARCHAR AS PROCEDURE_CODE_RAW,
    NULLIF(
        TRIM(code.value::VARCHAR),
        ''
    ) AS PROCEDURE_CODE_CLEAN
FROM RAW_EXTRACTION_RESULTS AS r,
LATERAL FLATTEN(
    input => r.RAW_EXTRACTION_RESPONSE:response:fee_schedule:code
) AS code
WHERE r.DOCUMENT_ID = $DOCUMENT_ID
  AND r.RUN_STATUS = $RUN_STATUS
ORDER BY
    r.PAGE_NUMBER,
    code.index;


-- Count procedure codes that become NULL after cleaning.
SELECT
    COUNT(*) AS NULL_PROCEDURE_CODES
FROM RAW_EXTRACTION_RESULTS AS r,
LATERAL FLATTEN(
    input => r.RAW_EXTRACTION_RESPONSE:response:fee_schedule:code
) AS code
WHERE r.DOCUMENT_ID = $DOCUMENT_ID
  AND r.RUN_STATUS = $RUN_STATUS
  AND NULLIF(TRIM(code.value::VARCHAR), '') IS NULL;


/*
4. MODIFIER CLEANING VALIDATION
*/

-- Compare raw modifier values with the expected cleaned values.
SELECT
    r.PAGE_NUMBER,
    modifier.index AS ROW_INDEX,
    modifier.value::VARCHAR AS MODIFIER_RAW,
    CASE
        WHEN TRIM(modifier.value::VARCHAR) IN ('', 'None')
            THEN NULL
        ELSE TRIM(modifier.value::VARCHAR)
    END AS MODIFIER_CLEAN
FROM RAW_EXTRACTION_RESULTS AS r,
LATERAL FLATTEN(
    input => r.RAW_EXTRACTION_RESPONSE:response:fee_schedule:modifier
) AS modifier
WHERE r.DOCUMENT_ID = $DOCUMENT_ID
  AND r.RUN_STATUS = $RUN_STATUS
ORDER BY
    r.PAGE_NUMBER,
    modifier.index;


-- Inspect distinct raw modifier values.
-- Useful for confirming which source values should map to NULL or remain unchanged.
SELECT DISTINCT
    modifier.value::VARCHAR AS MODIFIER_RAW
FROM RAW_EXTRACTION_RESULTS AS r,
LATERAL FLATTEN(
    input => r.RAW_EXTRACTION_RESPONSE:response:fee_schedule:modifier
) AS modifier
WHERE r.DOCUMENT_ID = $DOCUMENT_ID
  AND r.RUN_STATUS = $RUN_STATUS
ORDER BY MODIFIER_RAW;


-- Count modifier values that become NULL after cleaning.
SELECT
    COUNT(*) AS NULL_MODIFIERS_AFTER_CLEANING
FROM RAW_EXTRACTION_RESULTS AS r,
LATERAL FLATTEN(
    input => r.RAW_EXTRACTION_RESPONSE:response:fee_schedule:modifier
) AS modifier
WHERE r.DOCUMENT_ID = $DOCUMENT_ID
  AND r.RUN_STATUS = $RUN_STATUS
  AND (
      modifier.value IS NULL
      OR TRIM(modifier.value::VARCHAR) IN ('', 'None')
  );
