/**
 * Main Thread - Database Controller
 */
const startApp = () => {
    console.log("Starting Web Worker...");
    const worker = new Worker('worker.js');

    worker.onmessage = function(e) {
        if (e.data.type === 'ready') {
            console.log("🎊 SUCCESS: Database is live and persistent in the background!");
            // Here is where we will eventually trigger the UI to show up
        } else if (e.data.type === 'error') {
            console.error("❌ Worker Error:", e.data.message);
        }
    };
};

startApp();