/*
Purpose:
    Test the extraction of page-level content from a successfully parsed document
    before running the full extraction across the entire document.

    ND Medicaid fee schedule schema specific.
*/

/*
Step 1:
  Set the response format for AI extraction.
*/

/* ND baseline schema */
SET RESPONSE_FORMAT_JSON = '
{
  "schema": {
    "type": "object",
    "properties": {
      "fee_schedule": {
        "type": "object",
        "description": "Main Medicaid reimbursement table. Treat every source table row as a separate independent record, including consecutive rows with the same procedure code. All arrays must contain one element per source row and remain exactly index-aligned. Never move a value between columns, suppress duplicate procedure codes, or treat repeated procedure codes as continuations or modifiers.",
        "column_ordering": [
          "procedure_code",
          "modifier",
          "medicaid_fee"
        ],
        "properties": {    
          "procedure_code": {
            "type": "array",
            "description": "Procedure Code."
          },
          "modifier": {
            "type": "array",
            "description": "Modifier."
          },
          "medicaid_fee": {
            "type": "array",
            "description": "Medicaid Fee."
          }
        }
      }
    }
  }
}';

/*
Step 2: 
  Create a temporary table to store parsed pages.
*/
CREATE OR REPLACE TEMP TABLE TEMP_PARSE_PAGES AS
SELECT
    PARSE.DOCUMENT_ID,
    PARSE.PARSE_RUN_ID,

    PAGE.VALUE:index::NUMBER + 1 AS PAGE_NUMBER,  -- Adjust for 0-based index from FLATTEN to 1-based page number
    PAGE.VALUE:content::VARCHAR AS PAGE_TEXT

FROM RAW_PARSE_RESULTS AS PARSE,

LATERAL FLATTEN(
    INPUT => COALESCE(
        PARSE.RAW_PARSE_RESPONSE:value:pages,
        PARSE.RAW_PARSE_RESPONSE:pages
    )
) AS PAGE

WHERE PARSE.DOCUMENT_ID = $DOCUMENT_ID
  AND PARSE.PARSE_RUN_ID = $PARSE_RUN_ID
  AND PARSE.RUN_STATUS = 'SUCCESS';



/* Step 3: 
    Select a few pages to test the extraction logic. 
    Inspect page number and page text to verify that the correct pages are being extracted before running the full extraction across all pages.
*/
SELECT
    PAGE_NUMBER,
    PAGE_TEXT
FROM TEMP_PARSE_PAGES
WHERE PAGE_NUMBER IN (1, 12, 13, 14, 15, 100, 167, 200, 300);


/* Step 4: 
   Apply AI extraction to the selected pages.
   Inspect the results to verify that the extraction logic is working as expected before running the full extraction across all pages. 
*/
CREATE OR REPLACE TEMP TABLE TEMP_TEST_EXTRACTION_RESULTS AS
SELECT
  PAGE_NUMBER,
  AI_EXTRACT(
    text => PAGE_TEXT,
    responseFormat => PARSE_JSON($RESPONSE_FORMAT_JSON),
    scores => TRUE
  ) AS RAW_EXTRACTION_RESPONSE
FROM TEMP_PARSE_PAGES
WHERE PAGE_NUMBER IN (1, 12, 13, 14, 15, 100, 167, 200, 300);


/* Step 5:
   Quick validation of raw extraction responses.
*/

-- 5.1 Summary status of test extraction responses.
SELECT
  COUNT(*) AS TEST_PAGE_COUNT,
  COUNT_IF(
    RAW_EXTRACTION_RESPONSE:error IS NOT NULL
    AND NOT IS_NULL_VALUE(RAW_EXTRACTION_RESPONSE:error)
  ) AS ERROR_PAGE_COUNT,
  CASE
    WHEN COUNT(*) = 0 THEN 'NO_TEST_PAGES'
    WHEN COUNT_IF(
        RAW_EXTRACTION_RESPONSE:error IS NOT NULL
        AND NOT IS_NULL_VALUE(RAW_EXTRACTION_RESPONSE:error)
       ) > 0
      THEN 'REVIEW_ERRORS_FOUND'
    ELSE 'PASS'
  END AS TEST_STATUS
FROM TEMP_TEST_EXTRACTION_RESULTS;


/* Step 5.2:
    Per-page quick checks from raw response. 
*/
SELECT
  PAGE_NUMBER,
  RAW_EXTRACTION_RESPONSE:error AS EXTRACTION_ERROR,
  RAW_EXTRACTION_RESPONSE:scoring:scores:fee_schedule:score::FLOAT AS EXTRACTION_CONFIDENCE,
  COALESCE(
    ARRAY_SIZE(RAW_EXTRACTION_RESPONSE:response:fee_schedule:procedure_code),
    ARRAY_SIZE(RAW_EXTRACTION_RESPONSE:response:fee_schedule:cpt_code)
  ) AS CODE_ROW_COUNT,
  COALESCE(
    ARRAY_SIZE(RAW_EXTRACTION_RESPONSE:response:fee_schedule:modifier_1),
    ARRAY_SIZE(RAW_EXTRACTION_RESPONSE:response:fee_schedule:modifier)
  ) AS MODIFIER_COUNT,
  COALESCE(
    ARRAY_SIZE(RAW_EXTRACTION_RESPONSE:response:fee_schedule:medicaid_fee),
    ARRAY_SIZE(RAW_EXTRACTION_RESPONSE:response:fee_schedule:rate)
  ) AS FEE_OR_RATE_COUNT
FROM TEMP_TEST_EXTRACTION_RESULTS
ORDER BY PAGE_NUMBER;


/* Step 5.3:
   Full raw response inspection for each tested page. 
   Check if the extracted values are as expected under the target schema.
*/
      
SELECT
  PAGE_NUMBER,
  RAW_EXTRACTION_RESPONSE
FROM TEMP_TEST_EXTRACTION_RESULTS
ORDER BY PAGE_NUMBER;
