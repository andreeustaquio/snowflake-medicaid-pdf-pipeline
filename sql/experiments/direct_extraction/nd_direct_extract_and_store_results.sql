/*
Purpose:
Run AI_EXTRACT directly on the registered Medicaid fee schedule PDF
and store the raw extraction response for later evaluation and transformation.

Prerequisites:
- Run 00_config.sql
- Run 01_register_document.sql
- Verify the extraction schema from 02/02b, or define it manually

IMPORTANT:
Main constraint of using direct AI_EXTRACT on PDFs is that the entire PDF must fit within the model's context window. 
If the PDF is too large, the extraction will fail. 
The AI_EXTRACT function has a 125 page limit for the input PDF file and does not expose a page_filter parameter
that AI_PARSE_DOCUMENT has. Unable to filter pages to batch and this experiment is only suitable for small PDFs. 
For larger PDFs, use the pipeline approach with AI_PARSE_DOCUMENT and AI_EXTRACT on individual pages.

Raw extraction response:
{"error":"Maximum number of 125 pages exceeded. The document has 638 pages.","response":null}
*/


/*
Step 1:
Define the approved extraction schema. Use the schema proposed by the AI model in 02_analyze_schema.sql, or define your own schema manually.
*/

SET RESPONSE_FORMAT_JSON = '
{
  "schema": {
    "type": "object",
    "properties": {
      "fee_schedule": {
        "type": "object",
        "description": "Arkansas Medicaid Physician Fee Schedule",
        "column_ordering": [
          "procedure_code",
          "mod_1",
          "mod_2",
          "mod_3",
          "mod_4",
          "provider_program",
          "medicaid_maximum_allowed_amount"
        ],
        "properties": {
          "procedure_code": {
            "type": "array",
            "description": "Procedure Code"
          },
          "mod_1": {
            "type": "array",
            "description": "Mod 1"
          },
          "mod_2": {
            "type": "array",
            "description": "Mod 2"
          },
          "mod_3": {
            "type": "array",
            "description": "Mod 3"
          },
          "mod_4": {
            "type": "array",
            "description": "Mod 4"
          },
          "provider_program": {
            "type": "array",
            "description": "Provider Program"
          },
          "medicaid_maximum_allowed_amount": {
            "type": "array",
            "description": "Medicaid Maximum Allowed Amount"
          }
        }
      }
    }
  }
}';


/*
Step 2:
Run AI_EXTRACT directly on the PDF.
*/

CREATE OR REPLACE TEMP TABLE TEMP_EXTRACTION_RESULT AS
SELECT
    $DOCUMENT_ID AS DOCUMENT_ID,

    AI_EXTRACT(
        file => TO_FILE(
            '@MEDICAID_FEE_SCHEDULE_PDFS',
            $FILE_NAME
        ),

        responseFormat => PARSE_JSON($RESPONSE_FORMAT_JSON),

        scores => TRUE
    ) AS RAW_EXTRACTION_RESPONSE;


/*
Step 3:
Store the raw result.
*/

INSERT INTO RAW_EXTRACTION_RESULTS (
    DOCUMENT_ID,
    PARSE_RUN_ID,
    EXTRACTION_VERSION,
    INPUT_TYPE,
    PAGE_NUMBER,
    BATCH_ID,
    RESPONSE_FORMAT,
    SCORES_REQUESTED,
    RAW_EXTRACTION_RESPONSE,
    RUN_STATUS,
    ERROR_MESSAGE
)

SELECT
    DOCUMENT_ID,

    NULL AS PARSE_RUN_ID,

    $EXTRACTION_VERSION,

    'FILE_DIRECT' AS INPUT_TYPE,

    NULL AS PAGE_NUMBER,

    NULL AS BATCH_ID,

    PARSE_JSON($RESPONSE_FORMAT_JSON) AS RESPONSE_FORMAT,

    TRUE AS SCORES_REQUESTED,

    RAW_EXTRACTION_RESPONSE,

    CASE
        WHEN RAW_EXTRACTION_RESPONSE:error IS NULL
            THEN 'SUCCESS'
        ELSE 'FAILED'
    END AS RUN_STATUS,

    RAW_EXTRACTION_RESPONSE:error::VARCHAR AS ERROR_MESSAGE

FROM TEMP_EXTRACTION_RESULT;


/*
Step 4:
Inspect the stored result.
*/

SELECT *
FROM RAW_EXTRACTION_RESULTS
WHERE DOCUMENT_ID = $DOCUMENT_ID
ORDER BY EXTRACTION_RESULT_ID DESC
LIMIT 1;
