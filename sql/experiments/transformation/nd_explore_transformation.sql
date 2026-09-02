/*
Purpose:
Explore and validate transformation logic for the ND simple fee schedule.

This script is for development and experimentation only.

It is used to:
1. Inspect stored AI_EXTRACT results.
2. Understand the extracted array structure.
3. Test row alignment.
4. Develop and test field-cleaning logic.
5. Preview the expected standardized fee schedule rows.

The finalized transformation logic is implemented in the pipeline load script.
*/

SET DOCUMENT_ID = 1;

/* Step 1:
    Confirm the JSON path correct for the target stored extraction results.
*/ 

SELECT
    DOCUMENT_ID,
    PARSE_RUN_ID,
    PAGE_NUMBER,

    RAW_EXTRACTION_RESPONSE:response:fee_schedule:code AS CODES,
    RAW_EXTRACTION_RESPONSE:response:fee_schedule:modifier AS MODIFIERS,
    RAW_EXTRACTION_RESPONSE:response:fee_schedule:medicaid_fee AS MEDICAID_FEES

FROM RAW_EXTRACTION_RESULTS

WHERE DOCUMENT_ID = $DOCUMENT_ID
  AND RUN_STATUS = 'SUCCESS'
ORDER BY PAGE_NUMBER;

/* Step 2:
    Flatten all three arrays and join them by the same array index so each fee-schedule row stays aligned.
    Extraction stored each field as an array, so we need to flatten them and join by the same index to get one row per fee schedule record.
*/
SELECT
    r.DOCUMENT_ID,
    r.PARSE_RUN_ID,
    r.PAGE_NUMBER,

    code.index AS ROW_INDEX,
    code.value::VARCHAR AS PROCEDURE_CODE,
    modifier.value::VARCHAR AS MODIFIER,
    fee.value::VARCHAR AS MEDICAID_FEE

FROM RAW_EXTRACTION_RESULTS AS r,

LATERAL FLATTEN(
    input => r.RAW_EXTRACTION_RESPONSE:response:fee_schedule:code
) AS code,

LATERAL FLATTEN(
    input => r.RAW_EXTRACTION_RESPONSE:response:fee_schedule:modifier
) AS modifier,

LATERAL FLATTEN(
    input => r.RAW_EXTRACTION_RESPONSE:response:fee_schedule:medicaid_fee
) AS fee

WHERE r.DOCUMENT_ID = $DOCUMENT_ID
  AND r.RUN_STATUS = 'SUCCESS'
  AND code.index = modifier.index
  AND code.index = fee.index

ORDER BY
    r.PAGE_NUMBER,
    code.index;


/*
    Step 3:
    Validation check:  

    EXPECTED_ROWS should match TOTAL_ROWS.
    Both total extracted code count and total flattened row count should match.
    This confirms that the JSON path is correct and that the extraction results are stored as expected.
*/

-- Count the total extracted codes across all pages.
SELECT
    PAGE_NUMBER,
    ARRAY_SIZE(RAW_EXTRACTION_RESPONSE:response:fee_schedule:code) AS CODE_COUNT,
    ARRAY_SIZE(RAW_EXTRACTION_RESPONSE:response:fee_schedule:modifier) AS MODIFIER_COUNT,
    ARRAY_SIZE(RAW_EXTRACTION_RESPONSE:response:fee_schedule:medicaid_fee) AS FEE_COUNT
FROM RAW_EXTRACTION_RESULTS
WHERE DOCUMENT_ID = $DOCUMENT_ID
  AND RUN_STATUS = 'SUCCESS'
ORDER BY PAGE_NUMBER;


-- Count the total flattened result across all pages.
SELECT
    SUM(
        ARRAY_SIZE(
            RAW_EXTRACTION_RESPONSE:response:fee_schedule:code
        )
    ) AS EXPECTED_ROWS
FROM RAW_EXTRACTION_RESULTS
WHERE DOCUMENT_ID = $DOCUMENT_ID
  AND RUN_STATUS = 'SUCCESS';


-- Count total rows across all pages to confirm the total number of fee schedule records extracted.
SELECT COUNT(*) AS TOTAL_ROWS
FROM (
    SELECT
        r.DOCUMENT_ID,
        r.PARSE_RUN_ID,
        r.PAGE_NUMBER,

        code.index AS ROW_INDEX,
        code.value::VARCHAR AS PROCEDURE_CODE,
        modifier.value::VARCHAR AS MODIFIER,
        fee.value::VARCHAR AS MEDICAID_FEE

    FROM RAW_EXTRACTION_RESULTS AS r,

    LATERAL FLATTEN(
        input => r.RAW_EXTRACTION_RESPONSE:response:fee_schedule:code
    ) AS code,

    LATERAL FLATTEN(
        input => r.RAW_EXTRACTION_RESPONSE:response:fee_schedule:modifier
    ) AS modifier,

    LATERAL FLATTEN(
        input => r.RAW_EXTRACTION_RESPONSE:response:fee_schedule:medicaid_fee
    ) AS fee

    WHERE r.DOCUMENT_ID = $DOCUMENT_ID
    AND r.RUN_STATUS = 'SUCCESS'
    AND code.index = modifier.index
    AND code.index = fee.index

    ORDER BY
        r.PAGE_NUMBER,
        code.index
);


/* Step 4:
    Clean procedure codes.
    Trim whitespace and convert empty strings to NULL.
*/
SELECT
    r.DOCUMENT_ID,
    r.PARSE_RUN_ID,
    r.PAGE_NUMBER,
    code.index AS ROW_INDEX,

    NULLIF(
        TRIM(code.value::VARCHAR),
        ''
    ) AS PROCEDURE_CODE,

    modifier.value::VARCHAR AS MODIFIER_RAW,
    fee.value::VARCHAR AS MEDICAID_FEE_RAW

FROM RAW_EXTRACTION_RESULTS AS r,

LATERAL FLATTEN(
    input => r.RAW_EXTRACTION_RESPONSE:response:fee_schedule:code
) AS code,

LATERAL FLATTEN(
    input => r.RAW_EXTRACTION_RESPONSE:response:fee_schedule:modifier
) AS modifier,

LATERAL FLATTEN(
    input => r.RAW_EXTRACTION_RESPONSE:response:fee_schedule:medicaid_fee
) AS fee

WHERE r.DOCUMENT_ID = $DOCUMENT_ID
  AND r.RUN_STATUS = 'SUCCESS'
  AND code.index = modifier.index
  AND code.index = fee.index

ORDER BY
    r.PAGE_NUMBER,
    code.index;


/* Step 5:
    Clean modifier codes.
    Trim whitespace and convert empty strings to NULL. 
    Convert 'None' likely produced by AI_EXTRACT for empty fields, to NULL.
*/
SELECT
    r.DOCUMENT_ID,
    r.PARSE_RUN_ID,
    r.PAGE_NUMBER,
    code.index AS ROW_INDEX,

    CASE
        WHEN TRIM(modifier.value::VARCHAR) IN ('', 'None')
            THEN NULL
        ELSE TRIM(modifier.value::VARCHAR)
    END AS MODIFIER,

    modifier.value::VARCHAR AS MODIFIER_RAW,
    fee.value::VARCHAR AS MEDICAID_FEE_RAW

FROM RAW_EXTRACTION_RESULTS AS r,

LATERAL FLATTEN(
    input => r.RAW_EXTRACTION_RESPONSE:response:fee_schedule:code
) AS code,

LATERAL FLATTEN(
    input => r.RAW_EXTRACTION_RESPONSE:response:fee_schedule:modifier
) AS modifier,

LATERAL FLATTEN(
    input => r.RAW_EXTRACTION_RESPONSE:response:fee_schedule:medicaid_fee
) AS fee

WHERE r.DOCUMENT_ID = $DOCUMENT_ID
  AND r.RUN_STATUS = 'SUCCESS'
  AND code.index = modifier.index
  AND code.index = fee.index

ORDER BY
    r.PAGE_NUMBER,
    code.index;


/* Step 6:
    Clean Medicaid fee amounts.
    Trim whitespace, remove '$', remove ','and convert empty strings to NULL.
    Removed comma, TRY_TO_DECIMAL won't convert a string with a comma to decimal, returns NULL.
*/

SELECT
    r.DOCUMENT_ID,
    r.PARSE_RUN_ID,
    r.PAGE_NUMBER,
    code.index AS ROW_INDEX,

    NULLIF(
        TRIM(
            REPLACE(fee.value::VARCHAR, '$', '')    
        ),
        ''
    ) AS MEDICAID_FEE_CLEAN,

    TRY_TO_DECIMAL(
        REPLACE(
            REPLACE(fee.value::VARCHAR, '$', ''),
            ',',
            ''
        ),
        12,
        2
    ) AS MEDICAID_FEE,

    modifier.value::VARCHAR AS MODIFIER_RAW,
    fee.value::VARCHAR AS MEDICAID_FEE_RAW

FROM RAW_EXTRACTION_RESULTS AS r,

LATERAL FLATTEN(
    input => r.RAW_EXTRACTION_RESPONSE:response:fee_schedule:code
) AS code,

LATERAL FLATTEN(
    input => r.RAW_EXTRACTION_RESPONSE:response:fee_schedule:modifier
) AS modifier,

LATERAL FLATTEN(
    input => r.RAW_EXTRACTION_RESPONSE:response:fee_schedule:medicaid_fee
) AS fee

WHERE r.DOCUMENT_ID = $DOCUMENT_ID
  AND r.RUN_STATUS = 'SUCCESS'
  AND code.index = modifier.index
  AND code.index = fee.index

ORDER BY
    r.PAGE_NUMBER,
    code.index;


/* Step 7:
Preview cleaned and standardized extraction results.
*/

SELECT
    r.DOCUMENT_ID,
    r.PARSE_RUN_ID,
    r.PAGE_NUMBER,
    code.index AS ROW_INDEX,

    -- Clean procedure code
    NULLIF(
        TRIM(code.value::VARCHAR),
        ''
    ) AS PROCEDURE_CODE,

    -- Clean modifier
    CASE
        WHEN TRIM(modifier.value::VARCHAR) IN ('', 'None')
            THEN NULL
        ELSE TRIM(modifier.value::VARCHAR)
    END AS MODIFIER,

    -- Clean and convert Medicaid fee
    TRY_TO_DECIMAL(
        NULLIF(
            TRIM(REPLACE(fee.value::VARCHAR, '$', '')),
            ''
        ),
        12,
        2
    ) AS MEDICAID_FEE

FROM RAW_EXTRACTION_RESULTS AS r,

LATERAL FLATTEN(
    input => r.RAW_EXTRACTION_RESPONSE:response:fee_schedule:code
) AS code,

LATERAL FLATTEN(
    input => r.RAW_EXTRACTION_RESPONSE:response:fee_schedule:modifier
) AS modifier,

LATERAL FLATTEN(
    input => r.RAW_EXTRACTION_RESPONSE:response:fee_schedule:medicaid_fee
) AS fee

WHERE r.DOCUMENT_ID = $DOCUMENT_ID
  AND r.RUN_STATUS = 'SUCCESS'
  AND code.index = modifier.index
  AND code.index = fee.index

ORDER BY
    r.PAGE_NUMBER,
    code.index;


/* Step 8:
Preview final standardized fee schedule rows.
*/

SELECT
    r.DOCUMENT_ID,
    r.PARSE_RUN_ID,
    r.EXTRACTION_RESULT_ID,
    r.PAGE_NUMBER,
    code.index AS SOURCE_ROW_INDEX,

    'ND' AS STATE_CODE,

    NULLIF(
        TRIM(code.value::VARCHAR),
        ''
    ) AS PROCEDURE_CODE,

    CASE
        WHEN TRIM(modifier.value::VARCHAR) IN ('', 'None')
            THEN NULL
        ELSE TRIM(modifier.value::VARCHAR)
    END AS MODIFIER,

    TRY_TO_DECIMAL(
        NULLIF(
            TRIM(
                REPLACE(fee.value::VARCHAR, '$', '')
            ),
            ''
        ),
        12,
        2
    ) AS MEDICAID_FEE

FROM RAW_EXTRACTION_RESULTS AS r,

LATERAL FLATTEN(
    input => r.RAW_EXTRACTION_RESPONSE:response:fee_schedule:code
) AS code,

LATERAL FLATTEN(
    input => r.RAW_EXTRACTION_RESPONSE:response:fee_schedule:modifier
) AS modifier,

LATERAL FLATTEN(
    input => r.RAW_EXTRACTION_RESPONSE:response:fee_schedule:medicaid_fee
) AS fee

WHERE r.DOCUMENT_ID = $DOCUMENT_ID
  AND r.RUN_STATUS = 'SUCCESS'
  AND code.index = modifier.index
  AND code.index = fee.index

ORDER BY
    r.PAGE_NUMBER,
    code.index;
