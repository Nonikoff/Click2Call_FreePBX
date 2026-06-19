<?php
/**
 * Agent Status Background Worker for Click2Call
 * Updates the agent_status table by polling AMI for PJSIP endpoint states.
 * 
 * This script should be run in the background (e.g., via systemd).
 */

if (php_sapi_name() !== 'cli') {
    die("This script can only be run from command line\n");
}

/**
 * Log worker activity
 */
function worker_log($message, $type = 'INFO') {
    $timestamp = date('Y-m-d H:i:s');
    $logMessage = "[$timestamp] [$type] $message" . PHP_EOL;
    $logFile = '/var/log/asterisk/agent_status_worker.log';
    
    echo $logMessage;
    
    if (!file_exists($logFile)) {
        @touch($logFile);
        @chown($logFile, 'asterisk');
        @chgrp($logFile, 'asterisk');
        @chmod($logFile, 0664);
    }
    
    @file_put_contents($logFile, $logMessage, FILE_APPEND);
}

// Load FreePBX bootstrap
if (!file_exists('/etc/freepbx.conf')) {
    worker_log("FreePBX configuration file not found at /etc/freepbx.conf", 'ERROR');
    die("ERROR: FreePBX configuration file not found\n");
}

try {
    require_once('/etc/freepbx.conf');
    global $astman, $db;
    
    if (!isset($astman)) {
        worker_log("AMI (astman) not available in FreePBX bootstrap", 'ERROR');
        die("ERROR: AMI not available\n");
    }

    worker_log("Agent Status Worker starting...");
    
    // Ensure AMI is connected
    if (!$astman->connected()) {
        $astman->reconnect();
    }

    if (!$astman->connected()) {
        worker_log("Could not connect to AMI. Please check Asterisk Manager settings.", 'ERROR');
        die("ERROR: AMI connection failed\n");
    }
    
    worker_log("Connected to AMI. Starting polling loop.");
    
    while (true) {
        try {
            // Reconnect if connection dropped
            if (!$astman->connected()) {
                worker_log("AMI disconnected, attempting to reconnect...", 'WARN');
                $astman->reconnect();
                if (!$astman->connected()) {
                    sleep(5);
                    continue;
                }
                worker_log("AMI reconnected.");
            }
            
            // Get PJSIP states
            $response = $astman->Command('pjsip list endpoints');
            
            if (isset($response['data'])) {
                $lines = explode("\n", $response['data']);
                $states = [];
                
                foreach ($lines as $line) {
                    $line = trim($line);
                    // Match pattern: Endpoint:  <ext>/<profile>   <State>   <channels>
                    if (preg_match('/^Endpoint:\s+(\S+)\s+(\S+(?:\s+\S+)*)\s+\d+\s+of/', $line, $matches)) {
                        $endpointFull = $matches[1];
                        $stateRaw = strtolower(trim($matches[2]));
                        
                        $parts = explode('/', $endpointFull);
                        $ext = $parts[0];
                        
                        // Filter out non-numeric extensions (e.g. trunk endpoints, anonymous)
                        if (!is_numeric($ext)) continue;
                        
                        // Map PJSIP state to Click2Call simplified status
                        $status = 'unavailable';
                        if ($stateRaw === 'not in use') {
                            $status = 'available';
                        } elseif (in_array($stateRaw, ['in use', 'busy', 'ringing'])) {
                            $status = 'busy';
                        }
                        
                        $states[$ext] = $status;
                    }
                }
                
                if (!empty($states)) {
                    // Update database in a single transaction or bulk if many, but for simplicity
                    // and stability with FreePBX DB layer, we'll do ON DUPLICATE KEY UPDATE.
                    // We also want to mark extensions that are NO LONGER in the list as unavailable?
                    // PJSIP list endpoints usually returns all configured.
                    
                    foreach ($states as $ext => $status) {
                        $sql = "INSERT INTO `asterisk`.`agent_status` (extension, status, last_updated) 
                                VALUES (?, ?, NOW()) 
                                ON DUPLICATE KEY UPDATE status = VALUES(status), last_updated = NOW()";
                        $db->query($sql, array($ext, $status));
                    }
                }
            } else {
                worker_log("Failed to get response from AMI Command", 'WARN');
            }
            
        } catch (Exception $e) {
            worker_log("Error in loop: " . $e->getMessage(), 'ERROR');
            // Try to reconnect next time
            if (isset($astman)) {
                $astman->reconnect();
            }
        }
        
        // Wait 2 seconds before next poll
        sleep(2);
    }
    
} catch (Exception $e) {
    worker_log("Fatal worker error: " . $e->getMessage(), 'ERROR');
    die("ERROR: " . $e->getMessage() . "\n");
}
