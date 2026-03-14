# Fabric Conference 2026

Samples used for the Fabric Conference 2026 sessions.

## Samples

### [`light-the-light`](./light-the-light)

A C# .NET console application that demonstrates AI-powered function calling using the [Microsoft Agents Framework](https://github.com/microsoft/agents) and Azure OpenAI. It simulates a smart-home assistant that lets you control virtual lights through natural language.

**What it does:**
- Runs a console loop where you type commands like *"Turn on the living room light"* or *"Add a kitchen light"*
- The AI agent automatically calls the right tool (`GetLights`, `ChangeState`, `AddLight`, `RemoveLight`) to fulfil the request
- Serves a web UI at `http://localhost:5000` showing the current state of all lights in real time (via WebSockets)
- Optionally streams telemetry to Application Insights or Azure AI Foundry Tracing so you can observe every call made to the model

### [`light-the-light-mcp`](./light-the-light-mcp)

The same light-management scenario reimplemented as a standalone [Model Context Protocol (MCP)](https://modelcontextprotocol.io) server. Instead of running its own AI agent, it exposes the light-control logic as MCP tools that any MCP-compatible client can call.

**What it does:**
- Starts an HTTP server at `http://localhost:5000` that exposes an MCP endpoint at `/mcp`
- Registers the same four tools (`GetLights`, `ChangeState`, `AddLight`, `RemoveLight`) as MCP tools so external AI clients (e.g. GitHub Copilot, Claude Desktop) can discover and invoke them
- Also serves the same real-time web UI as the `light-the-light` sample (via WebSockets at `/ws`)

### [`sql-mcp-ai-foundry`](./sql-mcp-ai-foundry)

An end-to-end demo showcasing SQL Server 2025 AI capabilities together with [Data API Builder (DAB)](https://aka.ms/dab) and a GitHub Copilot agent. It stores Wikipedia articles in SQL Server and enables rich semantic search over them.

**What it does:**
- Sets up a `WikipediaArticles` table in SQL Server 2025 with 1536-dimensional vector columns for title and content embeddings
- Demonstrates multiple search strategies over the Wikipedia dataset:
  - **Vector search** using DiskANN for approximate nearest-neighbour retrieval
  - **Full-text search** using BM25 ranking via `FREETEXTTABLE`
  - **Hybrid search** that combines both with Reciprocal Rank Fusion (RRF)
  - **Semantic reranking** of hybrid-search results using a Cohere model hosted on Azure AI Foundry
- Uses [Data API Builder](https://aka.ms/dab) (`DAB/dab-config.json`) to expose the `WikipediaArticles` table through REST, GraphQL, and an MCP endpoint — no custom API code required
- Includes a GitHub Copilot agent definition (`.github/agents/wikipedia.agent.md`) that connects to the DAB MCP server and lets you find, create, update, or delete Wikipedia articles using natural language directly from VS Code
