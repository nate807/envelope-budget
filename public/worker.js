// Load the library inside the worker
importScripts('sqlite3.js');

self.sqlite3InitModule({
    print: console.log,
    printErr: console.error,
}).then(async (sqlite3) => {
    try {
        console.log("🚀 Worker: SQLite3 Loaded.");

        // Now OpfsDb WILL work because we are in a worker thread
        const db = new sqlite3.oo1.OpfsDb('/budget.db', 'c');
        console.log("✅ Worker: Database opened in OPFS.");

        // Apply Schema
        const response = await fetch('schema.sql');
        const sqlSchema = await response.text();
        db.exec(sqlSchema);

        // Success! Send a message back to the main UI
        postMessage({ type: 'ready' });

    } catch (err) {
        postMessage({ type: 'error', message: err.message });
    }
});