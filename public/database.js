/**
 * SQLite WASM Initialization
 */
self.sqlite3InitModule({
    print: console.log,
    printErr: console.error,
}).then(async (sqlite3) => {
    try {
        console.log("Loaded SQLite3 version:", sqlite3.version.libVersion);

        // 1. Open the database in OPFS (Persistent storage) 
        const db = new sqlite3.oo1.OpfsDb('/budget.db', 'c');
        console.log("✅ Database opened in OPFS:", db.filename);

        // 2. Fetch the schema.sql file from your repo
        const response = await fetch('schema.sql');
        const sqlSchema = await response.text();

        // 3. Execute the schema [cite: 162]
        db.exec(sqlSchema);
        console.log("✅ Schema applied successfully!");

        // 4. Test Query: Pull default settings [cite: 172]
        const settings = [];
        db.exec({
            sql: "SELECT * FROM setting;",
            rowMode: 'object',
            callback: (row) => settings.push(row)
        });
        
        console.log("App Initialized. Current Settings:");
        console.table(settings);

    } catch (err) {
        console.error("❌ SQLite Initialization Error:", err.message);
    }
});