/**
 * Envelope Budget - Local Database Initializer
 */
const startApp = async () => {
    try {
        // 1. Initialize the module using the local global function
        const sqlite3 = await sqlite3InitModule({
            print: console.log,
            printErr: console.error,
        });

        console.log("🚀 SQLite3 Loaded. Version:", sqlite3.version.libVersion);

        // 2. Open (or create) the database in persistent browser storage
        const db = new sqlite3.oo1.OpfsDb('/budget.db', 'c');
        console.log("✅ Database opened in OPFS:", db.filename);

        // 3. Fetch your schema.sql from your own server
        const response = await fetch('schema.sql');
        const sqlSchema = await response.text();

        // 4. Run the schema to build your tables
        db.exec(sqlSchema);
        console.log("✅ Schema applied successfully!");

        // 5. Verification: Read the default settings
        const settings = [];
        db.exec({
            sql: "SELECT * FROM setting;",
            rowMode: 'object',
            callback: (row) => settings.push(row)
        });

        console.log("App Initialized. Current Settings:");
        console.table(settings);

    } catch (err) {
        // If this triggers, check if sqlite3.wasm is missing from your folder
        console.error("❌ Database Initialization Failed:", err);
    }
};

// Start the process
startApp();