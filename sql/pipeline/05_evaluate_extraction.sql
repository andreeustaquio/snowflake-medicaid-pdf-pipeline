/*
Purpose:
Validate stored AI_EXTRACT results before loading
the standardized fee schedule.

ND Medicaid fee schedule schema specific.

Checks:
1. Extraction status
2. Extraction evaluation / confidence
3. Array-length consistency
4. Sample extracted values
5. Procedure-code quality and code-type totals
6. Raw-response inspection

*/


/*
1. Check extraction status
*/
SELECT
    COUNT(*) AS TOTAL_RESULTS,
    COUNT_IF(RUN_STATUS = 'SUCCESS') AS SUCCESSFUL_RESULTS,
    COUNT_IF(RUN_STATUS = 'FAILED') AS FAILED_RESULTS
FROM RAW_EXTRACTION_RESULTS
WHERE DOCUMENT_ID = $DOCUMENT_ID
  AND PARSE_RUN_ID = $PARSE_RUN_ID
  AND SCHEMA_VERSION = $SCHEMA_VERSION
  AND EXTRACTION_VERSION = $EXTRACTION_VERSION;


/*
2. Evaluate each extraction result.

FAILED = technical extraction failure
REVIEW = successful extraction with missing/low confidence
PASS   = successful extraction above confidence threshold
*/
SELECT
    EXTRACTION_RESULT_ID,
    PAGE_NUMBER,
    RUN_STATUS,
    EXTRACTION_CONFIDENCE,
    ERROR_MESSAGE,

    CASE
        WHEN RUN_STATUS = 'FAILED'
            THEN 'FAILED'

        WHEN EXTRACTION_CONFIDENCE IS NULL
            THEN 'REVIEW'

        WHEN EXTRACTION_CONFIDENCE < $CONFIDENCE_THRESHOLD
            THEN 'REVIEW'

        ELSE 'PASS'
    END AS EVALUATION_STATUS

FROM RAW_EXTRACTION_RESULTS
WHERE DOCUMENT_ID = $DOCUMENT_ID
  AND PARSE_RUN_ID = $PARSE_RUN_ID
  AND SCHEMA_VERSION = $SCHEMA_VERSION
  AND EXTRACTION_VERSION = $EXTRACTION_VERSION

ORDER BY PAGE_NUMBER;


/*
2b. Summarize confidence for technically successful results.
*/
SELECT
    COUNT(*) AS TOTAL_SUCCESSFUL_RESULTS,

    COUNT_IF(
        EXTRACTION_CONFIDENCE IS NULL
        OR EXTRACTION_CONFIDENCE < $CONFIDENCE_THRESHOLD
    ) AS RESULTS_REQUIRING_REVIEW,

    MIN(EXTRACTION_CONFIDENCE) AS MIN_CONFIDENCE,
    AVG(EXTRACTION_CONFIDENCE) AS AVG_CONFIDENCE

FROM RAW_EXTRACTION_RESULTS
WHERE DOCUMENT_ID = $DOCUMENT_ID
  AND PARSE_RUN_ID = $PARSE_RUN_ID
  AND EXTRACTION_VERSION = $EXTRACTION_VERSION
  AND SCHEMA_VERSION = $SCHEMA_VERSION
  AND RUN_STATUS = 'SUCCESS';


/* 2c. Inspect confidence distribution of scores and identify any low-confidence results.
       Identify pages that may require additional review or re-extraction.
*/
SELECT
    EXTRACTION_RESULT_ID,
    PAGE_NUMBER,
    EXTRACTION_CONFIDENCE,
    RUN_STATUS
FROM RAW_EXTRACTION_RESULTS
WHERE DOCUMENT_ID = $DOCUMENT_ID
  AND PARSE_RUN_ID = $PARSE_RUN_ID
  AND EXTRACTION_VERSION = $EXTRACTION_VERSION
  AND SCHEMA_VERSION = $SCHEMA_VERSION
  AND RUN_STATUS = 'SUCCESS'
  AND EXTRACTION_CONFIDENCE IS NOT NULL
ORDER BY EXTRACTION_CONFIDENCE ASC;


/*
3. Check extracted array lengths.
    Page coverage and array-length match consistency.
*/
-- Source of truth: the number of procedure codes extracted from the document. No missing procedure codes should be present in the final extraction results.
SELECT
    COALESCE(
        SUM(
            ARRAY_SIZE(
            RAW_EXTRACTION_RESPONSE:response:fee_schedule:procedure_code
            )
        ),
    0
    ) AS TOTAL_ROWS_FROM_PROCEDURE_CODE
FROM RAW_EXTRACTION_RESULTS
WHERE DOCUMENT_ID = $DOCUMENT_ID
AND PARSE_RUN_ID = $PARSE_RUN_ID
AND EXTRACTION_VERSION = $EXTRACTION_VERSION
AND SCHEMA_VERSION = $SCHEMA_VERSION
AND RUN_STATUS = 'SUCCESS';


SELECT
    EXTRACTION_RESULT_ID,
    PAGE_NUMBER,

    ARRAY_SIZE(
        RAW_EXTRACTION_RESPONSE:response:fee_schedule:procedure_code
    ) AS PROCEDURE_CODE_COUNT,

    ARRAY_SIZE(
        RAW_EXTRACTION_RESPONSE:response:fee_schedule:modifier
    ) AS MODIFIER_COUNT,

    -- ARRAY_SIZE(
    --     RAW_EXTRACTION_RESPONSE:response:fee_schedule:procedure_short_desc
    -- ) AS PROCEDURE_SHORT_DESC_COUNT,

    ARRAY_SIZE(
        RAW_EXTRACTION_RESPONSE
            :response:fee_schedule:medicaid_fee
    ) AS MEDICAID_FEE_COUNT

FROM RAW_EXTRACTION_RESULTS
WHERE DOCUMENT_ID = $DOCUMENT_ID
  AND PARSE_RUN_ID = $PARSE_RUN_ID
  AND SCHEMA_VERSION = $SCHEMA_VERSION
  AND EXTRACTION_VERSION = $EXTRACTION_VERSION
  AND RUN_STATUS = 'SUCCESS'

ORDER BY PAGE_NUMBER;


/*
3b. Check whether extracted array lengths match.

Expected:
NO_DATA = no successful extraction rows to evaluate
PASS    = all arrays align for targeted fields
REVIEW  = one or more results have mismatched arrays
*/
SELECT
    CASE
        WHEN (
            SELECT COUNT(*)
            FROM RAW_EXTRACTION_RESULTS
            WHERE DOCUMENT_ID = $DOCUMENT_ID
              AND PARSE_RUN_ID = $PARSE_RUN_ID
              AND EXTRACTION_VERSION = $EXTRACTION_VERSION
              AND SCHEMA_VERSION = $SCHEMA_VERSION
              AND RUN_STATUS = 'SUCCESS'
        ) = 0
            THEN 'NO_DATA'
        WHEN (
            SELECT COUNT(*)
            FROM RAW_EXTRACTION_RESULTS
            WHERE DOCUMENT_ID = $DOCUMENT_ID
              AND PARSE_RUN_ID = $PARSE_RUN_ID
              AND EXTRACTION_VERSION = $EXTRACTION_VERSION
              AND SCHEMA_VERSION = $SCHEMA_VERSION
              AND RUN_STATUS = 'SUCCESS'
              AND (
                   ARRAY_SIZE(
                       RAW_EXTRACTION_RESPONSE:response:fee_schedule:procedure_code
                   )
                   != ARRAY_SIZE(
                       RAW_EXTRACTION_RESPONSE:response:fee_schedule:modifier
                   )
                OR ARRAY_SIZE(
                       RAW_EXTRACTION_RESPONSE:response:fee_schedule:procedure_code
                   )
                   != ARRAY_SIZE(
                       RAW_EXTRACTION_RESPONSE:response:fee_schedule:medicaid_fee
                   )
              )
        ) > 0
            THEN 'REVIEW'
        ELSE 'PASS'
    END AS ARRAY_LENGTH_STATUS,

    (
        SELECT COUNT(*)
        FROM RAW_EXTRACTION_RESULTS
        WHERE DOCUMENT_ID = $DOCUMENT_ID
          AND PARSE_RUN_ID = $PARSE_RUN_ID
          AND EXTRACTION_VERSION = $EXTRACTION_VERSION
          AND SCHEMA_VERSION = $SCHEMA_VERSION
          AND RUN_STATUS = 'SUCCESS'
    ) AS TOTAL_SUCCESS_RESULTS,

    (
        SELECT COUNT(*)
        FROM RAW_EXTRACTION_RESULTS
        WHERE DOCUMENT_ID = $DOCUMENT_ID
          AND PARSE_RUN_ID = $PARSE_RUN_ID
          AND EXTRACTION_VERSION = $EXTRACTION_VERSION
          AND SCHEMA_VERSION = $SCHEMA_VERSION
          AND RUN_STATUS = 'SUCCESS'
          AND (
               ARRAY_SIZE(
                   RAW_EXTRACTION_RESPONSE:response:fee_schedule:procedure_code
               )
               != ARRAY_SIZE(
                   RAW_EXTRACTION_RESPONSE:response:fee_schedule:modifier
               )
            OR ARRAY_SIZE(
                   RAW_EXTRACTION_RESPONSE:response:fee_schedule:procedure_code
               )
               != ARRAY_SIZE(
                   RAW_EXTRACTION_RESPONSE:response:fee_schedule:medicaid_fee
               )
          )
    ) AS MISMATCHED_RESULTS
;

/*
4. Inspect sample extraction results.
    Spot check a few pages to verify that the extracted values are as expected under the target schema.
*/
SELECT
    PAGE_NUMBER,
    EXTRACTION_CONFIDENCE,

    RAW_EXTRACTION_RESPONSE:response:fee_schedule
        AS FEE_SCHEDULE

FROM RAW_EXTRACTION_RESULTS

WHERE DOCUMENT_ID = $DOCUMENT_ID
  AND PARSE_RUN_ID = $PARSE_RUN_ID
  AND EXTRACTION_VERSION = $EXTRACTION_VERSION
  AND SCHEMA_VERSION = $SCHEMA_VERSION
  AND RUN_STATUS = 'SUCCESS'

ORDER BY PAGE_NUMBER
LIMIT 25;


/*
4b. Inspect 10 actual extracted rows.
*/
SELECT
    r.PAGE_NUMBER,
    code.INDEX AS ROW_INDEX,

    code.VALUE::VARCHAR
        AS PROCEDURE_CODE,

    GET(
        r.RAW_EXTRACTION_RESPONSE
            :response:fee_schedule:modifier,
        code.INDEX
    )::VARCHAR AS MODIFIER,

    GET(
        r.RAW_EXTRACTION_RESPONSE
            :response:fee_schedule:medicaid_fee,
        code.INDEX
    )::VARCHAR AS MEDICAID_FEE

FROM RAW_EXTRACTION_RESULTS AS r,

LATERAL FLATTEN(
    INPUT =>
        r.RAW_EXTRACTION_RESPONSE
            :response:fee_schedule:procedure_code
) AS code

WHERE r.DOCUMENT_ID = $DOCUMENT_ID
  AND r.PARSE_RUN_ID = $PARSE_RUN_ID
  AND r.EXTRACTION_VERSION = $EXTRACTION_VERSION
  AND r.SCHEMA_VERSION = $SCHEMA_VERSION
  AND r.RUN_STATUS = 'SUCCESS'

ORDER BY
    r.PAGE_NUMBER,
    code.INDEX

LIMIT 10;


/*
5. Inspect procedure codes containing uppercase letters.
*/
SELECT
    r.PAGE_NUMBER,
    code.INDEX AS ROW_INDEX,
    code.VALUE::VARCHAR AS PROCEDURE_CODE

FROM RAW_EXTRACTION_RESULTS AS r,

LATERAL FLATTEN(
    INPUT =>
        r.RAW_EXTRACTION_RESPONSE
            :response:fee_schedule:procedure_code
) AS code

WHERE r.DOCUMENT_ID = $DOCUMENT_ID
  AND r.PARSE_RUN_ID = $PARSE_RUN_ID
  AND r.EXTRACTION_VERSION = $EXTRACTION_VERSION
  AND r.SCHEMA_VERSION = $SCHEMA_VERSION
  AND r.RUN_STATUS = 'SUCCESS'
  AND REGEXP_LIKE(
      code.VALUE::VARCHAR,
      '.*[A-Z].*'
  )

ORDER BY
    r.PAGE_NUMBER,
    code.INDEX;


/*
5b. Code-type totals and add-up check.

This helps confirm extracted procedure-code rows are fully accounted for:
- numeric-only codes
- codes containing letters
- other formats (blank/symbol/mixed anomalies)
*/
SELECT
    (
        SELECT COUNT(*)
        FROM RAW_EXTRACTION_RESULTS AS r,
        LATERAL FLATTEN(
            INPUT => r.RAW_EXTRACTION_RESPONSE:response:fee_schedule:procedure_code
        ) AS code
        WHERE r.DOCUMENT_ID = $DOCUMENT_ID
          AND r.PARSE_RUN_ID = $PARSE_RUN_ID
          AND r.EXTRACTION_VERSION = $EXTRACTION_VERSION
          AND r.SCHEMA_VERSION = $SCHEMA_VERSION
          AND r.RUN_STATUS = 'SUCCESS'
    ) AS TOTAL_PROCEDURE_CODE_ROWS,

    (
        SELECT COUNT(*)
        FROM RAW_EXTRACTION_RESULTS AS r,
        LATERAL FLATTEN(
            INPUT => r.RAW_EXTRACTION_RESPONSE:response:fee_schedule:procedure_code
        ) AS code
        WHERE r.DOCUMENT_ID = $DOCUMENT_ID
          AND r.PARSE_RUN_ID = $PARSE_RUN_ID
          AND r.EXTRACTION_VERSION = $EXTRACTION_VERSION
          AND r.SCHEMA_VERSION = $SCHEMA_VERSION
          AND r.RUN_STATUS = 'SUCCESS'
          AND REGEXP_LIKE(TRIM(code.VALUE::VARCHAR), '^[0-9]+$')
    ) AS NUMERIC_ONLY_CODES,

    (
        SELECT COUNT(*)
        FROM RAW_EXTRACTION_RESULTS AS r,
        LATERAL FLATTEN(
            INPUT => r.RAW_EXTRACTION_RESPONSE:response:fee_schedule:procedure_code
        ) AS code
        WHERE r.DOCUMENT_ID = $DOCUMENT_ID
          AND r.PARSE_RUN_ID = $PARSE_RUN_ID
          AND r.EXTRACTION_VERSION = $EXTRACTION_VERSION
          AND r.SCHEMA_VERSION = $SCHEMA_VERSION
          AND r.RUN_STATUS = 'SUCCESS'
          AND REGEXP_LIKE(TRIM(code.VALUE::VARCHAR), '.*[A-Za-z].*')
    ) AS CODES_WITH_LETTERS,

    (
        SELECT COUNT(*)
        FROM RAW_EXTRACTION_RESULTS AS r,
        LATERAL FLATTEN(
            INPUT => r.RAW_EXTRACTION_RESPONSE:response:fee_schedule:procedure_code
        ) AS code
        WHERE r.DOCUMENT_ID = $DOCUMENT_ID
          AND r.PARSE_RUN_ID = $PARSE_RUN_ID
          AND r.EXTRACTION_VERSION = $EXTRACTION_VERSION
          AND r.SCHEMA_VERSION = $SCHEMA_VERSION
          AND r.RUN_STATUS = 'SUCCESS'
          AND NOT REGEXP_LIKE(TRIM(code.VALUE::VARCHAR), '^[0-9]+$')
          AND NOT REGEXP_LIKE(TRIM(code.VALUE::VARCHAR), '.*[A-Za-z].*')
    ) AS OTHER_FORMAT_CODES,

    CASE
        WHEN (
            (
                SELECT COUNT(*)
                FROM RAW_EXTRACTION_RESULTS AS r,
                LATERAL FLATTEN(
                    INPUT => r.RAW_EXTRACTION_RESPONSE:response:fee_schedule:procedure_code
                ) AS code
                WHERE r.DOCUMENT_ID = $DOCUMENT_ID
                  AND r.PARSE_RUN_ID = $PARSE_RUN_ID
                  AND r.EXTRACTION_VERSION = $EXTRACTION_VERSION
                  AND r.SCHEMA_VERSION = $SCHEMA_VERSION
                  AND r.RUN_STATUS = 'SUCCESS'
                  AND REGEXP_LIKE(TRIM(code.VALUE::VARCHAR), '^[0-9]+$')
            )
            +
            (
                SELECT COUNT(*)
                FROM RAW_EXTRACTION_RESULTS AS r,
                LATERAL FLATTEN(
                    INPUT => r.RAW_EXTRACTION_RESPONSE:response:fee_schedule:procedure_code
                ) AS code
                WHERE r.DOCUMENT_ID = $DOCUMENT_ID
                  AND r.PARSE_RUN_ID = $PARSE_RUN_ID
                  AND r.EXTRACTION_VERSION = $EXTRACTION_VERSION
                  AND r.SCHEMA_VERSION = $SCHEMA_VERSION
                  AND r.RUN_STATUS = 'SUCCESS'
                  AND REGEXP_LIKE(TRIM(code.VALUE::VARCHAR), '.*[A-Za-z].*')
            )
            +
            (
                SELECT COUNT(*)
                FROM RAW_EXTRACTION_RESULTS AS r,
                LATERAL FLATTEN(
                    INPUT => r.RAW_EXTRACTION_RESPONSE:response:fee_schedule:procedure_code
                ) AS code
                WHERE r.DOCUMENT_ID = $DOCUMENT_ID
                  AND r.PARSE_RUN_ID = $PARSE_RUN_ID
                  AND r.EXTRACTION_VERSION = $EXTRACTION_VERSION
                  AND r.SCHEMA_VERSION = $SCHEMA_VERSION
                  AND r.RUN_STATUS = 'SUCCESS'
                  AND NOT REGEXP_LIKE(TRIM(code.VALUE::VARCHAR), '^[0-9]+$')
                  AND NOT REGEXP_LIKE(TRIM(code.VALUE::VARCHAR), '.*[A-Za-z].*')
            )
        )
        =
        (
            SELECT COUNT(*)
            FROM RAW_EXTRACTION_RESULTS AS r,
            LATERAL FLATTEN(
                INPUT => r.RAW_EXTRACTION_RESPONSE:response:fee_schedule:procedure_code
            ) AS code
            WHERE r.DOCUMENT_ID = $DOCUMENT_ID
              AND r.PARSE_RUN_ID = $PARSE_RUN_ID
              AND r.EXTRACTION_VERSION = $EXTRACTION_VERSION
              AND r.SCHEMA_VERSION = $SCHEMA_VERSION
              AND r.RUN_STATUS = 'SUCCESS'
        )
            THEN 'PASS'
        ELSE 'REVIEW'
    END AS CODE_TOTAL_CHECK;


/*
6. Detailed raw-response inspection.

Includes both successful and failed results.
*/
SELECT
    EXTRACTION_RESULT_ID,
    PAGE_NUMBER,
    RUN_STATUS,
    EXTRACTION_CONFIDENCE,
    ERROR_MESSAGE,

    RAW_EXTRACTION_RESPONSE:response
        AS EXTRACTED_DATA,

    RAW_EXTRACTION_RESPONSE:scoring
        AS EXTRACTION_SCORES,

    RAW_EXTRACTION_RESPONSE:error
        AS EXTRACTION_ERROR

FROM RAW_EXTRACTION_RESULTS

WHERE DOCUMENT_ID = $DOCUMENT_ID
  AND PARSE_RUN_ID = $PARSE_RUN_ID
  AND EXTRACTION_VERSION = $EXTRACTION_VERSION
  AND SCHEMA_VERSION = $SCHEMA_VERSION

ORDER BY PAGE_NUMBER;
