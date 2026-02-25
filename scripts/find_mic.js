// --- 1. Hook Low-Level AudioUnit Properties ---
const setProp = Module.findExportByName(null, "AudioUnitSetProperty");

if (setProp) {
    Interceptor.attach(setProp, {
        onEnter(args) {
            const inID = args[1].toInt32();
            const inScope = args[2].toInt32();
            const inElement = args[3].toInt32();
            
            // Convert ID to 4-character string (FourCC)
            const idStr = String.fromCharCode(
                (inID >> 24) & 0xFF,
                (inID >> 16) & 0xFF,
                (inID >> 8) & 0xFF,
                inID & 0xFF
            );

            // 2005 = 'sica' (Set Input Callback)
            // 23   = 'serc' (Set Render Callback)
            if (inID === 2005 || inID === 23) {
                console.log(`\n[!] Callback Registration Detected!`);
                console.log(`    ID: ${inID} (${idStr}) | Scope: ${inScope} | Element: ${inElement}`);
                
                const cbStruct = args[4];
                const procPtr = cbStruct.readPointer();
                console.log(`    Callback Function Address: ${procPtr}`);
                
                // Try to find which module the callback belongs to
                const sym = DebugSymbol.fromAddress(procPtr);
                if (sym && sym.moduleName) {
                    console.log(`    Module: ${sym.moduleName} | Symbol: ${sym.name}`);
                }
            } else {
                // Log other properties at a lower priority
                console.log(`SetProp: ID=${inID} (${idStr}) Scope=${inScope}`);
            }
        }
    });
}

// --- 2. Hook AudioUnit Initialization ---
const auInit = Module.findExportByName(null, "AudioUnitInitialize");
if (auInit) {
    Interceptor.attach(auInit, {
        onEnter(args) {
            console.log(`\n[*] AudioUnitInitialize called on: ${args[0]}`);
        }
    });
}

// --- 3. Hook High-Level Obj-C Taps (AVFoundation) ---
if (ObjC.available) {
    try {
        const target = ObjC.classes.AVAudioInputNode['- installTapOnBus:bufferSize:format:block:'];
        if (target) {
            Interceptor.attach(target.implementation, {
                onEnter(args) {
                    console.log(`\n[!] High-level AVFoundation Tap detected on Bus: ${args[2]}`);
                }
            });
        }
    } catch (e) {
        console.log("AVAudioInputNode hook skipped (not used by this app version).");
    }
}

console.log("\n--- Frida Discovery Script Loaded ---");
console.log("Start a call in WhatsApp to trigger hooks...");
