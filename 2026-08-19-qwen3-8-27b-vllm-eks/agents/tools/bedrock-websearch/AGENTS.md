# Tools available to you

## Web search (use whenever you need current or live information)

Run this shell command to search the web and get a grounded answer with source URLs
(Amazon Bedrock does the search; you stay the reasoning model):

    python3 /opt/tools/bedrock_websearch.py "<your search query>"

Use it for anything about latest versions, recent events, or facts that may have changed
since training. Then answer from its output and cite the source URL(s).
