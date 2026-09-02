/*
Purpose:
    Parse the first page of the ND Medicaid fee schedule PDF document using AI_PARSE_DOCUMENT to validate document layout and content.
    
Process:
    1. Create a file reference to the ND Medicaid fee schedule PDF in the Snowflake stage.
    2. Parse the first page (page 0) using AI_PARSE_DOCUMENT in LAYOUT mode.
    3. Return the parsed document output for review.

Objects:
    Source stage: MEDICAID_FEE_SCHEDULE_PDFS
    Test file: ND_FeeSchedule.pdf
*/

/*
Session prerequisites:
- Set DATABASE, SCHEMA, and WAREHOUSE before running.

Example:
USE DATABASE <DB_NAME>;
USE SCHEMA <SCHEMA_NAME>;
USE WAREHOUSE <WAREHOUSE_NAME>;
*/

SELECT AI_PARSE_DOCUMENT(
    TO_FILE(
        '@MEDICAID_FEE_SCHEDULE_PDFS',
        'ND_FeeSchedule.pdf'
    ),
    {
        'mode': 'LAYOUT',
        'page_filter': [
            {
                'start': 0,
                'end': 1
            }
        ]
    },
    TRUE
) AS PARSED_DOCUMENT;
