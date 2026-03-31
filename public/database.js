/**
 * Envelope Budget - Database Initializer
 */
const startApp = async () => {
    try {
        // Explicitly check for the function
        if (typeof sqlite3InitModule !== 'function') {
            throw new Error("sqlite3InitModule is still not defined. Check your script loading order.");
        }

        const sqlite3 = await sqlite3InitModule({
            print: console.log,
            printErr: console.error,
        });

        console.log("🚀 SQLite3 Loaded. Version:", sqlite3.version.libVersion);

        // 1. Open persistent storage (OPFS) [cite: 5, 18-20]
        const db = new sqlite3.oo1.OpfsDb('/budget.db', 'c');
        
        // 2. Fetch your schema [cite: 5, 161-162]
        const response = await fetch('schema.sql');
        const sqlSchema = await response.text();

        // 3. Execute schema
        db.exec(sqlSchema);
        console.log("✅ Database Ready & Schema Applied.");

        // 4. Show the settings table from your schema 
        const settings = [];
        db.exec({
            sql: "SELECT * FROM setting;",
            rowMode: 'object',
            callback: (row) => settings.push(row)
        });
        console.table(settings);

    } catch (err) {
        console.error("❌ Initialization Failed:", err);
    }
};

// Execute the starter
startApp();