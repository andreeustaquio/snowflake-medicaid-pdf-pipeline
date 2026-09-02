/*
Purpose:
Transform successful raw extraction results and load them into
the configured standardized table.  

ND Medicaid fee schedule schema specific.

*/

/*
Session prerequisites:
Run 00_config.sql to set DATABASE, SCHEMA, and WAREHOUSE, parameters, and stage name before running this script.
*/

/*
Step 1: Preview rows that will be loaded
*/

SELECT
    OBJECT_KEYS(
        RAW_EXTRACTION_RESPONSE:response:fee_schedule
    ) AS FEE_SCHEDULE_KEYS
FROM RAW_EXTRACTION_RESULTS
WHERE DOCUMENT_ID = $DOCUMENT_ID
  AND PARSE_RUN_ID = $PARSE_RUN_ID
  AND EXTRACTION_VERSION = $EXTRACTION_VERSION
  AND SCHEMA_VERSION = $SCHEMA_VERSION
  AND RUN_STATUS = 'SUCCESS'
LIMIT 5;

/* Alter standardized table to add new columns if they don't exist. */

SELECT
    r.DOCUMENT_ID,
    r.PARSE_RUN_ID,
    r.EXTRACTION_RESULT_ID,
    r.PAGE_NUMBER,
    code.index AS SOURCE_ROW_INDEX,

    $STATE_CODE AS STATE_CODE,

    -- Clean procedure code
    NULLIF(
        TRIM(code.value::VARCHAR),
        ''
    ) AS PROCEDURE_CODE,

    -- Clean modifier
    CASE
        WHEN TRIM(
            GET(
                r.RAW_EXTRACTION_RESPONSE:response:fee_schedule:modifier,
                code.index
            )::VARCHAR
        ) IN ('', 'None')
            THEN NULL
        ELSE TRIM(
            GET(
                r.RAW_EXTRACTION_RESPONSE:response:fee_schedule:modifier,
                code.index
            )::VARCHAR
        )
    END AS MODIFIER,

    -- Clean and convert Medicaid fee
    TRY_TO_DECIMAL(
        NULLIF(
            TRIM(
                REPLACE(
                    REPLACE(
                        GET(
                            r.RAW_EXTRACTION_RESPONSE:response:fee_schedule:medicaid_fee,
                            code.index
                        )::VARCHAR,
                        '$',
                        ''
                    ),
                    ',',
                    ''
                )
            ),
            ''
        ),
        12,
        2
    ) AS MEDICAID_FEE,

    r.SCHEMA_VERSION AS SCHEMA_VERSION,
    $TRANSFORMATION_VERSION AS TRANSFORMATION_VERSION

FROM RAW_EXTRACTION_RESULTS AS r,

LATERAL FLATTEN(
    input => r.RAW_EXTRACTION_RESPONSE:response:fee_schedule:procedure_code
) AS code

WHERE r.DOCUMENT_ID = $DOCUMENT_ID
  AND r.PARSE_RUN_ID = $PARSE_RUN_ID
  AND r.SCHEMA_VERSION = $SCHEMA_VERSION
  AND r.EXTRACTION_VERSION = $EXTRACTION_VERSION
  AND r.RUN_STATUS = 'SUCCESS'

ORDER BY
    r.PAGE_NUMBER,
    code.index
LIMIT 50;



SELECT
    COUNT(*) AS SOURCE_ROW_COUNT
FROM RAW_EXTRACTION_RESULTS AS r,
LATERAL FLATTEN(
    input => r.RAW_EXTRACTION_RESPONSE:response:fee_schedule:procedure_code
) AS code
WHERE r.DOCUMENT_ID = $DOCUMENT_ID
  AND r.PARSE_RUN_ID = $PARSE_RUN_ID
  AND r.SCHEMA_VERSION = $SCHEMA_VERSION
  AND r.EXTRACTION_VERSION = $EXTRACTION_VERSION
  AND r.RUN_STATUS = 'SUCCESS';




/*
Step 2: Insert/load standardized rows into configured target table
*/
INSERT INTO IDENTIFIER($STANDARDIZED_TABLE_NAME) (
    DOCUMENT_ID,
    PARSE_RUN_ID,
    EXTRACTION_RESULT_ID,
    EXTRACTION_VERSION,
    PAGE_NUMBER,
    SOURCE_ROW_INDEX,
    STATE_CODE,
    PROCEDURE_CODE,
    MODIFIER,
    MEDICAID_FEE,
    SCHEMA_VERSION,
    TRANSFORMATION_VERSION
)

SELECT
    r.DOCUMENT_ID,
    r.PARSE_RUN_ID,
    r.EXTRACTION_RESULT_ID,
    r.EXTRACTION_VERSION,
    r.PAGE_NUMBER,
    code.index AS SOURCE_ROW_INDEX,

    $STATE_CODE AS STATE_CODE,

    -- Clean procedure code
    NULLIF(
        TRIM(code.value::VARCHAR),
        ''
    ) AS PROCEDURE_CODE,

    -- Clean modifier
    CASE
        WHEN TRIM(
            GET(
                r.RAW_EXTRACTION_RESPONSE:response:fee_schedule:modifier,
                code.index
            )::VARCHAR
        ) IN ('', 'None')
            THEN NULL
        ELSE TRIM(
            GET(
                r.RAW_EXTRACTION_RESPONSE:response:fee_schedule:modifier,
                code.index
            )::VARCHAR
        )
    END AS MODIFIER,

    -- Clean and convert Medicaid fee
    TRY_TO_DECIMAL(
        NULLIF(
            TRIM(
                REPLACE(
                    REPLACE(
                        GET(
                            r.RAW_EXTRACTION_RESPONSE:response:fee_schedule:medicaid_fee,
                            code.index
                        )::VARCHAR,
                        '$',
                        ''
                    ),
                    ',',
                    ''
                )
            ),
            ''
        ),
        12,
        2
    ) AS MEDICAID_FEE,

    r.SCHEMA_VERSION AS SCHEMA_VERSION,
    $TRANSFORMATION_VERSION AS TRANSFORMATION_VERSION

FROM RAW_EXTRACTION_RESULTS AS r,

LATERAL FLATTEN(
    input => r.RAW_EXTRACTION_RESPONSE:response:fee_schedule:procedure_code
) AS code

WHERE r.DOCUMENT_ID = $DOCUMENT_ID
  AND r.EXTRACTION_VERSION = $EXTRACTION_VERSION
  AND r.PARSE_RUN_ID = $PARSE_RUN_ID
  AND r.SCHEMA_VERSION = $SCHEMA_VERSION
  AND r.RUN_STATUS = 'SUCCESS'
  
  AND NOT EXISTS (
    SELECT 1
    FROM IDENTIFIER($STANDARDIZED_TABLE_NAME) AS s
    WHERE s.DOCUMENT_ID = r.DOCUMENT_ID
      AND s.PARSE_RUN_ID = r.PARSE_RUN_ID
      AND s.EXTRACTION_VERSION = r.EXTRACTION_VERSION
      AND s.PAGE_NUMBER = r.PAGE_NUMBER
      AND s.SOURCE_ROW_INDEX = code.index
  )
ORDER BY
    r.PAGE_NUMBER,
    code.index;


/*
Step 3: Confirm rows were loaded.
 */
SELECT COUNT(*) AS STANDARDIZED_ROW_COUNT
FROM IDENTIFIER($STANDARDIZED_TABLE_NAME)
WHERE DOCUMENT_ID = $DOCUMENT_ID
    AND PARSE_RUN_ID = $PARSE_RUN_ID
    AND SCHEMA_VERSION = $SCHEMA_VERSION
    AND EXTRACTION_VERSION = $EXTRACTION_VERSION;

SELECT
    COUNT(*) AS STANDARDIZED_ROW_COUNT,
    COUNT_IF(PROCEDURE_CODE IS NULL) AS NULL_PROCEDURE_CODE_COUNT,
    COUNT_IF(MEDICAID_FEE IS NULL) AS NULL_FEE_COUNT
FROM IDENTIFIER($STANDARDIZED_TABLE_NAME)
WHERE DOCUMENT_ID = $DOCUMENT_ID
    AND PARSE_RUN_ID = $PARSE_RUN_ID
    AND SCHEMA_VERSION = $SCHEMA_VERSION
    AND EXTRACTION_VERSION = $EXTRACTION_VERSION;


-- 3b. Dedupe-key check: one row per document/parse/extraction/page/source row.
SELECT
    CASE
        WHEN COUNT(*) = 0 THEN 'PASS'
        ELSE 'REVIEW'
    END AS DEDUPE_KEY_STATUS,
    COUNT(*) AS DUPLICATE_KEY_GROUPS
FROM (
    SELECT
        DOCUMENT_ID,
        PARSE_RUN_ID,
        EXTRACTION_VERSION,
        PAGE_NUMBER,
        SOURCE_ROW_INDEX,
        COUNT(*) AS ROWS_IN_GROUP
    FROM IDENTIFIER($STANDARDIZED_TABLE_NAME)
    WHERE DOCUMENT_ID = $DOCUMENT_ID
      AND PARSE_RUN_ID = $PARSE_RUN_ID
      AND SCHEMA_VERSION = $SCHEMA_VERSION
      AND EXTRACTION_VERSION = $EXTRACTION_VERSION
    GROUP BY
        DOCUMENT_ID,
        PARSE_RUN_ID,
        EXTRACTION_VERSION,
        PAGE_NUMBER,
        SOURCE_ROW_INDEX
    HAVING COUNT(*) > 1
);


/*
Step 4: Inspect rows
*/
SELECT *
FROM IDENTIFIER($STANDARDIZED_TABLE_NAME)
WHERE DOCUMENT_ID = $DOCUMENT_ID
ORDER BY
    PAGE_NUMBER,
    SOURCE_ROW_INDEX
LIMIT 100;


-- Compare row counts between source and standardized tables for the selected document.
SELECT
    SOURCE_ROW_COUNT,
    STANDARDIZED_ROW_COUNT,
    STANDARDIZED_ROW_COUNT - SOURCE_ROW_COUNT AS ROW_COUNT_DIFFERENCE
FROM (
    SELECT
        (
            SELECT COUNT(*)
            FROM RAW_EXTRACTION_RESULTS AS r,
            LATERAL FLATTEN(
                input => r.RAW_EXTRACTION_RESPONSE:response:fee_schedule:procedure_code
            ) AS code
            WHERE r.DOCUMENT_ID = $DOCUMENT_ID
              AND r.PARSE_RUN_ID = $PARSE_RUN_ID
              AND r.EXTRACTION_VERSION = $EXTRACTION_VERSION
              AND r.SCHEMA_VERSION = $SCHEMA_VERSION
              AND r.RUN_STATUS = 'SUCCESS'
        ) AS SOURCE_ROW_COUNT,

        (
            SELECT COUNT(*)
            FROM IDENTIFIER($STANDARDIZED_TABLE_NAME)
            WHERE DOCUMENT_ID = $DOCUMENT_ID
              AND PARSE_RUN_ID = $PARSE_RUN_ID
              AND EXTRACTION_VERSION = $EXTRACTION_VERSION
              AND SCHEMA_VERSION = $SCHEMA_VERSION
        ) AS STANDARDIZED_ROW_COUNT
);
