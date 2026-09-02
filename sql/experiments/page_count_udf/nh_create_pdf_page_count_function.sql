/*
Purpose:
    Create helper functions used by the PDF processing pipeline.
    Used to determine the number of pages in a PDF document before parsing, full or chunking logic.
*/

CREATE OR REPLACE FUNCTION GET_PDF_PAGE_COUNT(FILE_PATH STRING)
RETURNS INT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.10'
PACKAGES = ('snowflake-snowpark-python', 'pypdf')
HANDLER = 'get_page_count'
AS
$$
from snowflake.snowpark.files import SnowflakeFile
import pypdf

def get_page_count(file_path):
    with SnowflakeFile.open(file_path, 'rb') as f:
        reader = pypdf.PdfReader(f)
        return len(reader.pages)
$$;
