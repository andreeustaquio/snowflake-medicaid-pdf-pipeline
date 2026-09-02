# Archived SQL Experiments

This folder contains archived experiments used while developing the Medicaid fee schedule extraction pipeline.

These scripts are not part of the current orchestrated pipeline. They are retained to document alternative approaches, testing strategies, and design decisions that may be useful for future development.

## parse_baselines

Basic parsing experiments used to establish the initial document-processing workflow.

- `nd_first_page_parse.sql`
  Tests `AI_PARSE_DOCUMENT` on a single North Dakota page.

- `nd_full_document_parse.sql`
  Tests full-document parsing for the North Dakota fee schedule.

These scripts provide simple examples of using `AI_PARSE_DOCUMENT` before the pipeline added persistence, rerun checks, and orchestration.

## direct_extraction

Experiments that explored extracting structured data directly from parsed or source document content.

Includes:

- first-page parse-and-extract testing
- schema analysis
- schema evaluation
- direct extraction and result storage

These experiments helped compare simpler direct extraction approaches with the final staged parse-first pipeline.

## batching

Experiments that split document pages into groups before extraction.

Includes:

- creation of page batches
- batch-based extraction testing

The batching approach was useful for controlling extraction workload and testing subsets of pages. The final pipeline uses a simpler page-level extraction workflow, but these scripts are retained as examples for future batch-processing or retry strategies.

## transformation

Development scripts used to inspect extracted arrays, preserve row alignment, test field-cleaning logic, and preview standardized records.

The finalized transformation logic is implemented in the active pipeline load scripts.

## chunked_parsing

Experiments for documents that are difficult to parse reliably as a single full document.

Includes:

- full-versus-chunked parsing logic
- New Hampshire chunked parsing tests
- representative-page parsing tests

These experiments were developed while testing the larger and more complex New Hampshire fee schedule and may be useful if future documents require page-range or chunk-based processing.

## page_count_udf

Experimental Snowflake Python UDF work for determining PDF page count before parsing.

This approach could support future logic such as:

- choosing between full-document and chunked parsing
- estimating document size before processing
- automatically selecting a parsing strategy

The UDF was not included in the final pipeline to keep the current implementation simpler.

## Active Pipeline

The current supported pipeline is located in:

```text
sql/pipeline/
