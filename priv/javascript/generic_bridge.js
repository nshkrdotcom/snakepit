#!/usr/bin/env node

/**
 * Generic JavaScript/Node.js Bridge for Snakepit
 * 
 * A minimal, framework-agnostic bridge that demonstrates the protocol
 * without dependencies on any specific external packages.
 * 
 * This can serve as a template for creating your own JavaScript adapters.
 * 
 * To create a custom adapter:
 * 1. Create a new class that inherits from BaseCommandHandler
 * 2. Override getCommands() to define your command mapping
 * 3. Implement your command handler methods
 * 4. Pass an instance of your handler to ProtocolHandler
 * 
 * Example:
 *     class MyCustomHandler extends BaseCommandHandler {
 *         getCommands() {
 *             return {
 *                 ...super.getCommands(),
 *                 myCommand: this.handleMyCommand.bind(this)
 *             };
 *         }
 *         
 *         handleMyCommand(args) {
 *             return { result: "processed", input: args };
 *         }
 *     }
 *     
 *     const handler = new ProtocolHandler(new MyCustomHandler());
 *     handler.run();
 */

const process = require('process');
const Buffer = require('buffer').Buffer;

/**
 * Abstract base class for command handlers.
 * 
 * This provides a clean interface for creating custom adapters that can
 * be plugged into the ProtocolHandler without modifying the core bridge logic.
 */
class BaseCommandHandler {
    constructor() {
        this.startTime = Date.now();
        this.requestCount = 0;
    }
    
    /**
     * Define the command mapping. Subclasses should override this
     * to add or modify command handlers.
     * 
     * @returns {Object} Map of command names to handler functions
     */
    getCommands() {
        return {
            ping: this.handlePing.bind(this)
        };
    }
    
    /**
     * Get list of supported commands.
     * 
     * @returns {Array} List of command names
     */
    getSupportedCommands() {
        return Object.keys(this.getCommands());
    }
    
    /**
     * Process a command and return the result.
     * 
     * @param {string} command - The command name
     * @param {Object} args - Command arguments
     * @returns {Object} Command result
     * @throws {Error} If command is unknown
     */
    processCommand(command, args) {
        this.requestCount++;
        
        const commands = this.getCommands();
        const handler = commands[command];
        
        if (handler) {
            return handler(args);
        } else {
            throw new Error(`Unknown command: ${command}`);
        }
    }
    
    /**
     * Default ping handler that all adapters can use.
     * 
     * @param {Object} args - Command arguments
     * @returns {Object} Ping response
     */
    handlePing(args) {
        return {
            status: "ok",
            pid: process.pid,
            echo: args
        };
    }
}

/**
 * Generic command handler that provides basic commands without external dependencies.
 * This serves as both a working implementation and an example for custom adapters.
 */
class GenericCommandHandler extends BaseCommandHandler {
    constructor() {
        super();
    }
    
    /**
     * Define all commands supported by the generic handler.
     */
    getCommands() {
        return {
            ...super.getCommands(),
            echo: this.handleEcho.bind(this),
            compute: this.handleCompute.bind(this),
            random: this.handleRandom.bind(this),
            info: this.handleInfo.bind(this)
        };
    }
    
    handlePing(args) {
        /**
         * Enhanced ping with additional info.
         */
        return {
            status: "ok",
            bridge_type: "generic_javascript",
            uptime: (Date.now() - this.startTime) / 1000,
            requests_handled: this.requestCount,
            timestamp: Date.now() / 1000,
            node_version: process.version,
            platform: process.platform,
            worker_id: args.worker_id || "unknown",
            echo: args  // Echo back the arguments for testing
        };
    }
    
    handleEcho(args) {
        /**
         * Handle echo command - useful for testing.
         */
        return {
            status: "ok",
            echoed: args,
            timestamp: Date.now() / 1000
        };
    }
    
    handleCompute(args) {
        /**
         * Handle compute command - simple math operations.
         */
        try {
            const operation = args.operation || "add";
            const a = args.a || 0;
            const b = args.b || 0;
            
            let result;
            
            switch (operation) {
                case "add":
                    result = a + b;
                    break;
                case "subtract":
                    result = a - b;
                    break;
                case "multiply":
                    result = a * b;
                    break;
                case "divide":
                    if (b === 0) {
                        throw new Error("Division by zero");
                    }
                    result = a / b;
                    break;
                case "power":
                    result = Math.pow(a, b);
                    break;
                case "sqrt":
                    if (a < 0) {
                        throw new Error("Square root of negative number");
                    }
                    result = Math.sqrt(a);
                    break;
                default:
                    throw new Error(`Unsupported operation: ${operation}`);
            }
            
            // Additional validation
            if (!isFinite(result)) {
                throw new Error(`Invalid result: ${result}`);
            }
            
            return {
                status: "ok",
                operation: operation,
                inputs: { a: a, b: b },
                result: result,
                timestamp: Date.now() / 1000
            };
        } catch (error) {
            throw error;  // Let the protocol handler catch and format the error
        }
    }
    
    handleRandom(args) {
        /**
         * Handle random command - generate random numbers.
         */
        try {
            const type = args.type || "uniform";
            
            let value;
            
            switch (type) {
                case "uniform":
                    const min = args.min || 0;
                    const max = args.max || 1;
                    value = Math.random() * (max - min) + min;
                    break;
                    
                case "integer":
                    const intMin = args.min || 0;
                    const intMax = args.max || 100;
                    value = Math.floor(Math.random() * (intMax - intMin + 1)) + intMin;
                    break;
                    
                case "normal":
                    const mean = args.mean || 0;
                    const std = args.std || 1;
                    // Box-Muller transformation for normal distribution
                    const u1 = Math.random();
                    const u2 = Math.random();
                    const z0 = Math.sqrt(-2 * Math.log(u1)) * Math.cos(2 * Math.PI * u2);
                    value = z0 * std + mean;
                    break;
                    
                default:
                    throw new Error(`Unsupported random type: ${type}`);
            }
            
            return {
                status: "ok",
                type: type,
                parameters: args,
                value: value,
                timestamp: Date.now() / 1000
            };
        } catch (error) {
            throw error;  // Let the protocol handler catch and format the error
        }
    }
    
    handleInfo(args) {
        /**
         * Handle info command - return bridge information.
         */
        return {
            status: "ok",
            bridge_info: {
                name: "Generic Snakepit JavaScript Bridge",
                version: "1.0.0",
                supported_commands: this.getSupportedCommands(),
                uptime: (Date.now() - this.startTime) / 1000,
                total_requests: this.requestCount
            },
            system_info: {
                node_version: process.version,
                platform: process.platform,
                arch: process.arch,
                memory_usage: process.memoryUsage()
            },
            timestamp: Date.now() / 1000
        };
    }
}

class ProtocolHandler {
    /**
     * Handles the wire protocol for communication with Snakepit.
     * 
     * Protocol:
     * - 4-byte big-endian length header
     * - JSON payload
     */
    
    constructor(commandHandler = null) {
        /**
         * Initialize the protocol handler.
         * 
         * @param {BaseCommandHandler} commandHandler - An instance of BaseCommandHandler or its subclasses.
         *                                              If null, uses GenericCommandHandler as default.
         */
        this.commandHandler = commandHandler || new GenericCommandHandler();
        this.stdin = process.stdin;
        this.stdout = process.stdout;
        
        // Set stdin to raw mode for binary reading (only if it's a TTY)
        if (this.stdin.isTTY) {
            this.stdin.setRawMode(true);
        }
        this.readBuffer = Buffer.alloc(0);
        
        // Increase max listeners to handle high concurrency
        this.stdin.setMaxListeners(50);
        this.stdout.setMaxListeners(50);
    }
    
    readMessage() {
        /**
         * Read a message from stdin using the 4-byte length protocol.
         * Returns a Promise that resolves to the parsed message or null.
         */
        return new Promise((resolve) => {
            const tryRead = () => {
                // Do we have at least 4 bytes for the length header?
                if (this.readBuffer.length < 4) {
                    return false;
                }
                
                // Read the length (big-endian 32-bit integer)
                const length = this.readBuffer.readUInt32BE(0);
                
                // Do we have the complete message?
                if (this.readBuffer.length < 4 + length) {
                    return false;
                }
                
                try {
                    // Extract the JSON payload
                    const jsonData = this.readBuffer.subarray(4, 4 + length);
                    const message = JSON.parse(jsonData.toString('utf-8'));
                    
                    // Remove the processed message from buffer
                    this.readBuffer = this.readBuffer.subarray(4 + length);
                    
                    resolve(message);
                    return true;
                } catch (error) {
                    console.error(`Error parsing message: ${error}`, error);
                    resolve(null);
                    return true;
                }
            };
            
            // Try to read with current buffer
            if (tryRead()) {
                return;
            }
            
            // Set up data listener for more input
            const onData = (chunk) => {
                this.readBuffer = Buffer.concat([this.readBuffer, chunk]);
                if (tryRead()) {
                    this.stdin.removeListener('data', onData);
                }
            };
            
            this.stdin.on('data', onData);
            
            // Handle stdin end
            this.stdin.once('end', () => {
                this.stdin.removeListener('data', onData);
                resolve(null);
            });
        });
    }
    
    writeMessage(message) {
        /**
         * Write a message to stdout using the 4-byte length protocol.
         */
        try {
            // Encode JSON
            const jsonData = Buffer.from(JSON.stringify(message), 'utf-8');
            
            // Create length header (big-endian 32-bit)
            const lengthBuffer = Buffer.allocUnsafe(4);
            lengthBuffer.writeUInt32BE(jsonData.length, 0);
            
            // Write length header and JSON payload
            this.stdout.write(lengthBuffer);
            this.stdout.write(jsonData);
            
            return true;
        } catch (error) {
            console.error(`Error writing message: ${error}`);
            return false;
        }
    }
    
    async run() {
        /**
         * Main message loop.
         */
        console.error("Generic JavaScript Bridge started in pool-worker mode");
        
        try {
            while (true) {
                // Read request
                const request = await this.readMessage();
                if (request === null) {
                    break;
                }
                
                // Extract request details
                const requestId = request.id;
                const command = request.command;
                const args = request.args || {};
                
                let response;
                try {
                    // Process command
                    const result = this.commandHandler.processCommand(command, args);
                    
                    // Check if result indicates an error status
                    if (result && result.status === "error") {
                        response = {
                            id: requestId,
                            success: false,
                            error: result.error,
                            timestamp: new Date().toISOString()
                        };
                    } else {
                        // Send success response
                        response = {
                            id: requestId,
                            success: true,
                            result: result,
                            timestamp: new Date().toISOString()
                        };
                    }
                } catch (error) {
                    // Send error response
                    response = {
                        id: requestId,
                        success: false,
                        error: error.message,
                        timestamp: new Date().toISOString()
                    };
                }
                
                // Write response
                if (!this.writeMessage(response)) {
                    break;
                }
            }
        } catch (error) {
            console.error(`Protocol handler error: ${error}`);
            process.exit(1);
        }
    }
}

function main() {
    /**
     * Main entry point.
     */
    if (process.argv.includes("--help")) {
        console.log("Generic Snakepit JavaScript Bridge");
        console.log("Usage: node generic_bridge.js [--mode pool-worker]");
        console.log("");
        console.log("This bridge provides an extensible architecture for creating custom adapters.");
        console.log("See the module docstring for examples on how to create your own adapter.");
        console.log("");
        console.log("Default supported commands:");
        const handler = new GenericCommandHandler();
        handler.getSupportedCommands().forEach(cmd => {
            console.log(`  ${cmd}`);
        });
        return;
    }
    
    // Start protocol handler
    const handler = new ProtocolHandler();
    
    // Handle graceful shutdown
    process.on('SIGINT', () => {
        console.error("Bridge shutting down (SIGINT)");
        process.exit(0);
    });
    
    process.on('SIGTERM', () => {
        console.error("Bridge shutting down (SIGTERM)");
        process.exit(0);
    });
    
    // Handle pipe errors gracefully
    process.on('SIGPIPE', () => {
        console.error("Bridge pipe closed");
        process.exit(0);
    });
    
    // Handle uncaught errors
    process.on('uncaughtException', (error) => {
        console.error(`Bridge error: ${error}`);
        process.exit(1);
    });
    
    // Handle unhandled promise rejections
    process.on('unhandledRejection', (reason, promise) => {
        console.error(`Unhandled rejection at: ${promise}, reason: ${reason}`);
        process.exit(1);
    });
    
    // Start the main loop
    handler.run().catch((error) => {
        console.error(`Bridge error: ${error}`);
        process.exit(1);
    });
}

if (require.main === module) {
    main();
}