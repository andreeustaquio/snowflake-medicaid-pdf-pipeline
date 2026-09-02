/*
Purpose:
    Test the full document extraction workflow for one simple ND Medicaid fee schedule.

Tier 1 scope:
    This script validates the full-document extraction workflow for one simple ND Medicaid fee schedule.

Process:
    1. Confirm the latest successful parse of the target document exists in RAW_PARSE_RESULTS.
    2. Retrieve the raw parse response for the latest successful parse of the target document.
    2. Find the registry record matching the current file version.
    3. Create temporary batch table for the parsed pages.
    4. Verify the number of pages and batches in the temporary table.
    5. Run AI_EXTRACT on the first batch of pages (BATCH_ID = 0) to extract the fee schedule table. Display results.
    6. Inspect the number of pages and batches in the temporary table.
    7. Check to see if the extraction results are already stored in RAW_EXTRACTION_RESULTS by BATCH_ID. If not, insert the results into RAW_EXTRACTION_RESULTS.
    8. Insert into RAW_EXTRACTION_RESULTS if the extraction results for the first batch of pages (BATCH_ID = 0) are not already stored. 

Important:
    This script is intended for testing and validation purposes only. 

    In between the process steps there are optional validation queries to inspect the intermediate results. These queries are marked with the comment "IGNORE" and can be skipped if not needed.

    Inspect the PARSE_PAGE_BATCHES temporary table to see how the pages are grouped into batches. Each batch contains 50 pages, and the BATCH_ID is calculated as FLOOR(PAGE_NUMBER / 50).
    BATCH_ID and page numbers can be adjusted to process different batches of pages. For example, to process the second batch of pages (BATCH_ID = 1), change the WHERE clause in the AI_EXTRACT query to "WHERE BATCH_ID = 1".
    BATCH_ID and page numbers in this script are zero indexed, so the first batch of pages is BATCH_ID = 0 (pages 0-49), the second batch is BATCH_ID = 1 (pages 50-99), and so on.
*/


/*
Session prerequisites:
    Set the DATABASE, SCHEMA, and WAREHOUSE before running.

Example:

    USE DATABASE <DB_NAME>;
    USE SCHEMA <SCHEMA_NAME>;
    USE WAREHOUSE <WAREHOUSE_NAME>;
*/

/* Step 1:
   Confirm that the latest successful parse of the target document exists in RAW_PARSE_RESULTS.
*/

SELECT
    PARSE_RUN_ID,
    DOCUMENT_ID,
    PARSE_MODE,
    PARSED_AT
FROM RAW_PARSE_RESULTS
WHERE RUN_STATUS = 'SUCCESS'
ORDER BY PARSED_AT DESC
LIMIT 10;

/* Step 2:
   Retrieve the raw parse response for the latest successful parse of the target document.
*/
SELECT
    RAW_PARSE_RESPONSE
FROM RAW_PARSE_RESULTS
WHERE DOCUMENT_ID = 1
  AND RUN_STATUS = 'SUCCESS'
LIMIT 1;


/* Step 3:
Create a temporary batch table.
*/
CREATE OR REPLACE TEMP TABLE PARSE_PAGE_BATCHES AS

SELECT
    DOCUMENT_ID,
    PARSE_RUN_ID,
    f.index AS PAGE_NUMBER,
    f.value:content::VARCHAR AS PAGE_TEXT,

    FLOOR(f.index / 50) AS BATCH_ID

FROM RAW_PARSE_RESULTS r,

LATERAL FLATTEN(
    input => r.RAW_PARSE_RESPONSE:pages
) f

WHERE DOCUMENT_ID = 1
AND RUN_STATUS = 'SUCCESS';


/* Step 4:
   Verify the number of pages and batches in the temporary table.

   See the number of pages and batches in the temporary table, use batch number to process pages in groups of 50.
*/
SELECT
    BATCH_ID,
    COUNT(*) AS PAGE_COUNT
FROM PARSE_PAGE_BATCHES
GROUP BY BATCH_ID
ORDER BY BATCH_ID;


/* Step 5:
   Run AI_EXTRACT on the first batch of pages (BATCH_ID = 0) to extract the fee schedule table. Display results.
*/
SELECT

    DOCUMENT_ID,
    PARSE_RUN_ID,
    PAGE_NUMBER,
    BATCH_ID,

    AI_EXTRACT(

        text => PAGE_TEXT,

        responseFormat => {
            'schema': {
                'type':'object',

                'properties': {

                    'fee_schedule': {
                        'type':'object',

                        'description':
                            'ND Medicaid fee schedule table',

                        'properties': {

                            'code': {
                                'type':'array',
                                'description':
                                    'Procedure codes',
                                'items': {
                                    'type':'string'
                                }
                            },

                            'modifier': {
                                'type':'array',
                                'description':
                                    'Procedure modifiers',
                                'items': {
                                    'type':'string'
                                }
                            },

                            'medicaid_fee': {
                                'type':'array',
                                'description':
                                    'Medicaid fee amounts',
                                'items': {
                                    'type':'string'
                                }
                            }

                        }
                    }

                }
            }
        },

        scores => TRUE

    ) AS RAW_EXTRACTION_RESPONSE

FROM PARSE_PAGE_BATCHES

WHERE BATCH_ID = 0;    -- First batch of pages (0-49) for testing. Adjust BATCH_ID to process other batches.


/* Step 6:
   Inspect the number of pages and batches in the temporary table.
*/
SELECT COUNT(*)
FROM PARSE_PAGE_BATCHES;



/* Step 7:
   Check to see if the extraction results are already stored in RAW_EXTRACTION_RESULTS by BATCH_ID. If not, insert the results into RAW_EXTRACTION_RESULTS.
*/
SELECT
    DOCUMENT_ID,
    PARSE_RUN_ID,
    BATCH_ID,
    COUNT(*) AS ROW_COUNT
FROM RAW_EXTRACTION_RESULTS
GROUP BY
    DOCUMENT_ID,
    PARSE_RUN_ID,
    BATCH_ID
ORDER BY BATCH_ID;

-- Check the latest extraction results for the first batch of pages (BATCH_ID = 0).
SELECT
    EXTRACT_RUN_ID,
    DOCUMENT_ID,
    PAGE_NUMBER,
    BATCH_ID,
    RUN_STATUS,
    EXTRACTED_AT
FROM RAW_EXTRACTION_RESULTS
WHERE DOCUMENT_ID = 1
ORDER BY EXTRACTED_AT DESC;


-- Inspect first 50 pages
SELECT
    DOCUMENT_ID,
    PARSE_RUN_ID,
    PAGE_NUMBER,
    BATCH_ID
FROM PARSE_PAGE_BATCHES
WHERE BATCH_ID = 0
ORDER BY PAGE_NUMBER;

-- Verify parse source
SELECT
    DOCUMENT_ID,
    PARSE_RUN_ID,
    PARSE_MODE,
    PARSED_AT
FROM RAW_PARSE_RESULTS
WHERE DOCUMENT_ID = 1
AND RUN_STATUS = 'SUCCESS';


/* Step 8:
    Insert into RAW_EXTRACTION_RESULTS if the extraction results for the first batch of pages (BATCH_ID = 0) are not already stored. 
*/
INSERT INTO RAW_EXTRACTION_RESULTS
(
    DOCUMENT_ID,
    PARSE_RUN_ID,
    PAGE_NUMBER,
    BATCH_ID,
    EXTRACTION_VERSION,
    INPUT_TYPE,
    SCORES_REQUESTED,
    RESPONSE_FORMAT,
    RAW_EXTRACTION_RESPONSE,
    RUN_STATUS
)

SELECT
    DOCUMENT_ID,
    PARSE_RUN_ID,
    PAGE_NUMBER,
    BATCH_ID,

    'V1',
    'TEXT',
    TRUE,

    {
        'schema': {
            'type':'object',
            'properties': {

                'fee_schedule': {
                    'type':'object',

                    'properties': {

                        'code': {
                            'type':'array',
                            'items': {
                                'type':'string'
                            }
                        },

                        'modifier': {
                            'type':'array',
                            'items': {
                                'type':'string'
                            }
                        },

                        'medicaid_fee': {
                            'type':'array',
                            'items': {
                                'type':'string'
                            }
                        }

                    }
                }

            }
        }
    } AS RESPONSE_FORMAT,

    AI_EXTRACT(

        text => PAGE_TEXT,

        responseFormat => {
            'schema': {
                'type':'object',

                'properties': {

                    'fee_schedule': {
                        'type':'object',

                        'properties': {

                            'code': {
                                'type':'array',
                                'items': {
                                    'type':'string'
                                }
                            },

                            'modifier': {
                                'type':'array',
                                'items': {
                                    'type':'string'
                                }
                            },

                            'medicaid_fee': {
                                'type':'array',
                                'items': {
                                    'type':'string'
                                }
                            }

                        }
                    }

                }
            }
        },

        scores => TRUE       -- Request scores for the extraction results.

    ) AS RAW_EXTRACTION_RESPONSE,

    'SUCCESS' 

FROM PARSE_PAGE_BATCHES

WHERE BATCH_ID = 6;


-- View inserted results in RAW_EXTRACTION_RESULTS, by BATCH_ID
SELECT
    DOCUMENT_ID,
    PAGE_NUMBER,
    BATCH_ID,
    RUN_STATUS,
    RAW_EXTRACTION_RESPONSE
FROM RAW_EXTRACTION_RESULTS
WHERE BATCH_ID = 6
ORDER BY PAGE_NUMBER;


-- Check for duplicate pages
SELECT
    DOCUMENT_ID,
    PARSE_RUN_ID,
    PAGE_NUMBER,
    COUNT(*) AS ROW_COUNT
FROM RAW_EXTRACTION_RESULTS
WHERE BATCH_ID = 6
GROUP BY DOCUMENT_ID, PARSE_RUN_ID, PAGE_NUMBER
HAVING COUNT(*) > 1;
