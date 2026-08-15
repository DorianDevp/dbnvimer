# Commands

Every mapping has one, so nothing is reachable only by keystroke — and a 
few things have only a command. All 67 of them:

| Command | Does |
|---|---|
| `:DBClient` | open the sidebar |
| `:DBClientActivity` | who is connected and what they are running |
| `:DBClientAudit` | audit the schema for problems |
| `:DBClientBack` | back along the trail |
| `:DBClientBegin` | begin a transaction |
| `:DBClientBlastRadius` | which rows the statement would change |
| `:DBClientBroadcast` | run a statement on every open connection |
| `:DBClientCancel` | cancel the running statement |
| `:DBClientChart` | chart the current result set |
| `:DBClientClose` | close every connection |
| `:DBClientCommit` | commit |
| `:DBClientCompare` | compare with a saved snapshot |
| `:DBClientCompareConnections` | run one statement on two connections and diff |
| `:DBClientConnect` | open a connection, or pick one |
| `:DBClientConnections` | the connection manager |
| `:DBClientDDL` | the definition of an object |
| `:DBClientData` | open a table: `:DBClientData shop.customers` |
| `:DBClientDiagram` | entity relationship diagram |
| `:DBClientDisconnect` | close a connection |
| `:DBClientError` | explain the last error in full |
| `:DBClientErrors` | every error this session (`!` clears) |
| `:DBClientExplain` | explain the statement (`!` for ANALYZE) |
| `:DBClientExport` | export a table or the last result |
| `:DBClientExportPreset` | export using a named preset |
| `:DBClientFixture` | extract a row plus everything it needs |
| `:DBClientForward` | forward along the trail |
| `:DBClientGenerate` | generate code from a table |
| `:DBClientHelp` | every mapping group in one buffer |
| `:DBClientHistory` | query history |
| `:DBClientHypoIndex` | would this index help |
| `:DBClientImport` | import a CSV into a table |
| `:DBClientIndexes` | index usage for a schema |
| `:DBClientJoin` | build a join between two tables |
| `:DBClientLocks` | the lock tree |
| `:DBClientLog` | this session's statement log |
| `:DBClientMigrationReview` | what a migration will lock, and for how long |
| `:DBClientNotebook` | turn this markdown buffer into a notebook |
| `:DBClientPalette` | the generated palette and its contrast ratios |
| `:DBClientPipe` | pipe the result set through a shell command |
| `:DBClientProfile` | time a statement over several runs |
| `:DBClientQueries` | saved queries |
| `:DBClientQuery` | run the statement at the cursor |
| `:DBClientQueryBuffer` | open a query buffer |
| `:DBClientRecord` | everything related to the row under the cursor |
| `:DBClientReplace` | find and replace across every table |
| `:DBClientRestart` | restart the core daemon |
| `:DBClientRollback` | roll back |
| `:DBClientSaveQuery` | save the current query |
| `:DBClientSchemaDiff` | compare a schema across two connections |
| `:DBClientSchemaDrift` | compare the server against the committed schema |
| `:DBClientSchemaDump` | write the schema out as files (`!` keeps stale ones) |
| `:DBClientScratch` | quick query in a new tab |
| `:DBClientSearch` | search table and column names |
| `:DBClientSessions` | switch between open sessions |
| `:DBClientSnapshot` | save the result set as a snapshot |
| `:DBClientStatements` | the workload ranking (`!` saves a snapshot) |
| `:DBClientTail` | follow changes as they are committed |
| `:DBClientTailCheck` | explain what change streaming needs here |
| `:DBClientTailStop` | stop following |
| `:DBClientToggle` | toggle the sidebar |
| `:DBClientTrail` | pick a point on the navigation trail |
| `:DBClientUndoLog` | writes DBClient made, and how to undo them |
| `:DBClientWatch` | re-run a statement on a timer |
| `:DBClientWorkspaceClear` | forget it |
| `:DBClientWorkspaceRestore` | restore them |
| `:DBClientWorkspaceSave` | save the open buffers and connections |
| `:DBClientWorkspaceShow` | show what is saved |

