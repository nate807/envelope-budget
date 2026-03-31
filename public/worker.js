importScripts('sqlite3.js');

self.sqlite3InitModule({
    print: console.log,
    printErr: console.error,
}).then(async (sqlite3) => {
    try {
        console.log("🚀 Worker: SQLite3 Loaded.");

        const db = new sqlite3.oo1.OpfsDb('/budget.db', 'c');
        console.log("✅ Worker: Database opened in OPFS.");

        // FIX: Ensure we are fetching the schema from the root correctly
        const response = await fetch('/schema.sql'); 
        
        if (!response.ok) {
            throw new Error(`Could not find schema.sql (Status: ${response.status})`);
        }

        const sqlSchema = await response.text();

        // Check if we accidentally got HTML instead of SQL
        if (sqlSchema.trim().startsWith('<')) {
            throw new Error("Received HTML instead of SQL. Check your file paths!");
        }

        db.exec(sqlSchema);
        console.log("✅ Schema applied successfully!");

        postMessage({ type: 'ready' });

    } catch (err) {
        postMessage({ type: 'error', message: err.message });
    }
});