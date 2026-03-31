async function initDatabase() {
    // 1. Initialize the SQLite3 Module
    const sqlite3 = await sqlite3InitModule();
    
    // 2. Open the database in OPFS (Persistent Browser Storage)
    // This creates a file called 'budget.db' in the browser's internal disk
    const db = new sqlite3.oo1.OpfsDb('/budget.db', 'c');
    console.log("✅ Database opened in OPFS:", db.filename);

    // 3. Fetch your schema.sql file
    const response = await fetch('schema.sql');
    const sqlSchema = await response.text();

    // 4. Run the schema to create your tables (Envelopes, Transactions, etc.)
    db.exec(sqlSchema);
    console.log("✅ Schema applied successfully!");

    // 5. Verify: Pull the default settings from the database
    const settings = [];
    db.exec({
        sql: "SELECT * FROM setting;",
        rowMode: 'object',
        callback: (row) => settings.push(row)
    });
    
    console.log("Current App Settings:");
    console.table(settings);
}

// Kick off the initialization
initDatabase().catch(err => {
    console.error("❌ Database Initialization Error:", err);
});