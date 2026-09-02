/*
Purpose:
    Validate parsing across representative pages of the ND Medicaid fee schedule before processing the full PDF document.

Process:
    1. Parse selected beginning, middle, and ending pages, including a page that has all 3 columns populated.
    2. Store the parse output in a temporary table for further review.
    3. Flatten and display each parsed page for review.

Objects:
    Source stage: MEDICAID_FEE_SCHEDULE_PDFS
    Test file: ND_FeeSchedule.pdf
    Temporary table: TEMP_ND_PARSE
 */

/*
Session prerequisites:
- Set DATABASE, SCHEMA, and WAREHOUSE before running.

Example:
USE DATABASE <DB_NAME>;
USE SCHEMA <SCHEMA_NAME>;
USE WAREHOUSE <WAREHOUSE_NAME>;
*/


CREATE OR REPLACE TEMP TABLE TEMP_ND_PARSE AS
SELECT AI_PARSE_DOCUMENT(
    TO_FILE(
        '@MEDICAID_FEE_SCHEDULE_PDFS',
        'ND_FeeSchedule.pdf'
    ),
    {
        'mode': 'LAYOUT',
        'page_filter': [    -- Representative pages to validate beginning, middle, end of the document.
            {
                'start': 0,
                'end': 1        
            },
            {
                'start': 160,
                'end': 161
            },
            {
                'start': 180,   -- Page including all 3 columns populated.
                'end': 181
            },
            {
                'start': 321,
                'end': 322
            }
        ]
    },
    TRUE
) AS PARSE_OUTPUT;


/* 
   Flatten page to review the content of stored result.
*/

SELECT
    PAGE.VALUE:index::NUMBER AS PAGE_INDEX,
    PAGE.VALUE:content::VARCHAR AS PAGE_CONTENT
FROM TEMP_ND_PARSE,
LATERAL FLATTEN(
    INPUT => PARSE_OUTPUT:value:pages
) PAGE
ORDER BY PAGE_INDEX;
