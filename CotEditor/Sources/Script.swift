/*
 
 Script.swift
 
 CotEditor
 https://coteditor.com
 
 Created by 1024jp on 2016-10-22.
 
 ------------------------------------------------------------------------------
 
 © 2004-2007 nakamuxu
 © 2014-2016 1024jp
 
 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at
 
 https://www.apache.org/licenses/LICENSE-2.0
 
 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 
 */

import Cocoa

enum ScriptingEventType: String {
    
    case documentOpened = "document opened"
    case documentSaved = "document saved"
    
    
    var eventID: AEEventID {
        
        switch self {
        case .documentOpened: return AEEventID(code: "edod")
        case .documentSaved: return AEEventID(code: "edsd")
        }
    }
    
}



enum ScriptingFileType {
    
    case appleScript
    case shellScript
    
}



struct ScriptDescriptor {
    
    // MARK: Public Properties
    
    let url: URL
    let name: String
    let type: ScriptingFileType?
    let shortcut: Shortcut
    let eventTypes: [ScriptingEventType]
    let ordering: Int?
    
    
    
    // MARK: Private Properties
    
    private static let extensions: [ScriptingFileType:[String]] = [
        .appleScript: ["applescript", "scpt", "scptd"],
        .shellScript: ["sh", "pl", "php", "rb", "py", "js"]
    ]
    
    
    
    // MARK: -
    // MARK: Public Methods
    
    /// Create a descriptor that represents an user script at given URL.
    ///
    /// `Contents/Info.plist` in the script at `url` will be read if they exist.
    ///
    /// - parameter url: the location of an user script
    init(at url: URL) {
        
        // Extract from URL
        
        self.url = url
        
        self.type = ScriptDescriptor.extensions.first { $0.value.contains(url.pathExtension) }?.key
        
        var name = url.deletingPathExtension().lastPathComponent
        
        let shortcut = Shortcut(keySpecChars: url.deletingPathExtension().pathExtension)
        if shortcut.modifierMask.isEmpty {
            self.shortcut = Shortcut.none
        } else {
            self.shortcut = shortcut
            
            // Remove the shortcut specification from the script name
            name = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        }
        
        if let range = name.range(of: "^[0-9]+\\)", options: .regularExpression) {
            // Remove the parenthesis at last
            let orderingString = name.substring(to: name.index(before: range.upperBound))
            self.ordering = Int(orderingString)
            
            // Remove the ordering number from the script name
            name.removeSubrange(range)
        } else {
            self.ordering = nil
        }
        
        self.name = name
        
        // Extract from Info.plist
        
        let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        
        if let names = info?["CotEditorHandlers"] as? [String] {
            self.eventTypes = names.flatMap { ScriptingEventType(rawValue: $0) }
        } else {
            self.eventTypes = []
        }
    }
    
    
    /// Create and return an user script instance
    ///
    /// - returns: An instance of `Script` created by the receiver.
    ///            Returns `nil` if the script type is unsupported.
    func makeScript() -> Script? {
        
        guard let type = self.type else { return nil }
        
        switch type {
        case .appleScript: return AppleScript(with: self)
        case .shellScript: return ShellScript(with: self)
        }
    }
}



protocol Script {
    
    // MARK: Properties
    
    /// A script descriptor the receiver was created from.
    var descriptor: ScriptDescriptor { get }
    
    // MARK: Methods
    
    /// Execute the script with the default way.
    func run() throws
    
    
    /// Execute the script by sending it the given Apple event.
    ///
    /// Events the script cannot handle must be ignored with no errors.
    func run(withAppleEvent event: NSAppleEventDescriptor?) throws
    
    
}



extension Script {
    
    func run(withAppleEvent event: NSAppleEventDescriptor?) throws {
        // ignore every request with an event by default
    }
    
    
}



// MARK: -

final class AppleScript: Script {
    
    // MARK: Script Properties
    
    let descriptor: ScriptDescriptor
    
    
    
    // MARK: -
    // MARK: Lifecycle
    
    init(with descriptor: ScriptDescriptor) {
        self.descriptor = descriptor
    }
    
    
    
    // MARK: Script Methods
    
    /// run script
    /// - throws: Error by NSUserScriptTask
    func run() throws {
        
        try self.run(withAppleEvent: nil)
    }
    
    
    /// Execute the AppleScript script by sending it the given Apple event.
    ///
    /// Any script errors will be written to the console panel.
    ///
    /// - parameter event: the apple event
    ///
    /// - throws: `ScriptFileError` and any errors by `NSUserScriptTask.init(url:)`
    ///           
    func run(withAppleEvent event: NSAppleEventDescriptor?) throws {
        
        guard self.descriptor.url.isReachable else {
            throw ScriptFileError(kind: .existance, url: self.descriptor.url)
        }
        
        let task = try NSUserAppleScriptTask(url: self.descriptor.url)
        let scriptName = self.descriptor.name
        
        task.execute(withAppleEvent: event) { (result: NSAppleEventDescriptor?, error: Error?) in
            if let error = error {
                writeToConsole(message: error.localizedDescription, scriptName: scriptName)
            }
        }
    }
    
    
}



final class ShellScript: Script {
    
    // MARK: Script Properties
    
    let descriptor: ScriptDescriptor
    
    
    
    // MARK: -
    // MARK: Lifecycle
    
    init(with descriptor: ScriptDescriptor) {
        self.descriptor = descriptor
    }
    
    
    
    // MARK: Private Enum
    
    private enum OutputType: String, ScriptToken {
        
        case replaceSelection = "ReplaceSelection"
        case replaceAllText = "ReplaceAllText"
        case insertAfterSelection = "InsertAfterSelection"
        case appendToAllText = "AppendToAllText"
        case pasteBoard = "Pasteboard"
        
        static var token = "CotEditorXOutput"
    }
    
    
    private enum InputType: String, ScriptToken {
        
        case selection = "Selection"
        case allText = "AllText"
        
        static var token = "CotEditorXInput"
    }
    
    
    
    // MARK: Script Methods
    
    /// run script
    /// - throws: ScriptFileError or Error by NSUserScriptTask
    func run() throws {
        
        // check script file
        guard self.descriptor.url.isReachable else {
            throw ScriptFileError(kind: .existance, url: self.descriptor.url)
        }
        guard self.descriptor.url.isExecutable ?? false else {
            throw ScriptFileError(kind: .permission, url: self.descriptor.url)
        }
        guard let script = self.content, !script.isEmpty else {
            throw ScriptFileError(kind: .read, url: self.descriptor.url)
        }
        
        // fetch target document
        weak var document = NSDocumentController.shared().currentDocument as? Document
        
        // read input
        let input: String?
        if let inputType = InputType(scanning: script) {
            do {
                input = try self.readInputString(type: inputType, editor: document)
            } catch let error {
                writeToConsole(message: error.localizedDescription, scriptName: self.descriptor.name)
                return
            }
        } else {
            input = nil
        }
        
        // get output type
        let outputType = OutputType(scanning: script)
        
        // prepare file path as argument if available
        let arguments: [String] = {
            guard let path = document?.fileURL?.path else { return [] }
            return [path]
        }()
        
        // create task
        let task = try NSUserUnixTask(url: self.descriptor.url)
        
        // set pipes
        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardInput = inPipe.fileHandleForReading
        task.standardOutput = outPipe.fileHandleForWriting
        task.standardError = errPipe.fileHandleForWriting
        
        // set input data asynchronously if available
        if let data = input?.data(using: .utf8) {
            inPipe.fileHandleForWriting.writeabilityHandler = { (handle: FileHandle) in
                handle.write(data)
                handle.closeFile()
            }
        }
        
        let scriptName = self.descriptor.name
        var isCancelled = false  // user cancel state
        
        // read output asynchronously for safe with huge output
        if let outputType = outputType {
            outPipe.fileHandleForReading.readToEndOfFileInBackgroundAndNotify()
            var observer: NSObjectProtocol?
            observer = NotificationCenter.default.addObserver(forName: .NSFileHandleReadToEndOfFileCompletion, object: outPipe.fileHandleForReading, queue: nil) { (note: Notification) in
                NotificationCenter.default.removeObserver(observer!)
                
                guard
                    !isCancelled,
                    let data = note.userInfo?[NSFileHandleNotificationDataItem] as? Data,
                    let output = String(data: data, encoding: .utf8)
                    else { return }
                
                do {
                    try ShellScript.applyOutput(output, editor: document, type: outputType)
                } catch let error {
                    writeToConsole(message: error.localizedDescription, scriptName: scriptName)
                }
            }
        }
        
        // execute
        task.execute(withArguments: arguments) { error in
            // on user cancel
            if let error = error as? POSIXError, error.code == .ENOTBLK {
                isCancelled = true
                return
            }
            
            // put error message on the sconsole
            let errorData = errPipe.fileHandleForReading.readDataToEndOfFile()
            if let message = String(data: errorData, encoding: .utf8), !message.isEmpty {
                writeToConsole(message: message, scriptName: scriptName)
            }
        }
    }
    
    
    // MARK: Private Methods
    
    /// read content of script file
    private lazy var content: String? = {
        
        guard let data = try? Data(contentsOf: self.descriptor.url) else { return nil }
        
        for encoding in EncodingManager.shared.defaultEncodings {
            guard let encoding = encoding else { continue }
            
            if let contentString = String(data: data, encoding: encoding) {
                return contentString
            }
        }
        
        return nil
    }()
    
    
    /// return document content conforming to the input type
    /// - throws: ScriptError
    private func readInputString(type: InputType, editor: Editable?) throws -> String {
        
        guard let editor = editor else {
            throw ScriptError.noInputTarget
        }
        
        switch type {
        case .selection:
            return editor.selectedString
            
        case .allText:
            return editor.string
        }
    }
    
    
    /// apply results conforming to the output type to the frontmost document
    /// - throws: ScriptError
    private static func applyOutput(_ output: String, editor: Editable?, type: OutputType) throws {
        
        if type == .pasteBoard {
            let pasteboard = NSPasteboard.general()
            pasteboard.declareTypes([NSStringPboardType], owner: nil)
            guard pasteboard.setString(output, forType: NSStringPboardType) else {
                NSBeep()
                return
            }
            return
        }
        
        guard let editor = editor else {
            throw ScriptError.noOutputTarget
        }
        
        DispatchQueue.main.async {
            switch type {
            case .replaceSelection:
                editor.insert(string: output)
                
            case .replaceAllText:
                editor.replaceAllString(with: output)
                
            case .insertAfterSelection:
                editor.insertAfterSelection(string: output)
                
            case .appendToAllText:
                editor.append(string: output)
                
            case .pasteBoard:
                assertionFailure()
            }
        }
    }
    
}



// MARK: - Error

struct ScriptFileError: LocalizedError {
    
    enum ErrorKind {
        case existance
        case read
        case open
        case permission
    }
    
    let kind: ErrorKind
    let url: URL
    
    
    var errorDescription: String? {
        
        switch self.kind {
        case .existance:
            return String(format: NSLocalizedString("The script “%@” does not exist.", comment: ""), self.url.lastPathComponent)
        case .read:
            return String(format: NSLocalizedString("The script “%@” couldn’t be read.", comment: ""), self.url.lastPathComponent)
        case .open:
            return String(format: NSLocalizedString("The script file “%@” couldn’t be opened.", comment: ""), self.url.path)
        case .permission:
            return String(format: NSLocalizedString("The script “%@” can’t be executed because you don’t have the execute permission.", comment: ""), self.url.lastPathComponent)
        }
    }
    
    
    var recoverySuggestion: String? {
        
        switch self.kind {
        case .permission:
            return NSLocalizedString("Check permission of the script file.", comment: "")
        default:
            return NSLocalizedString("Check the script file.", comment: "")
        }
    }
    
}



private enum ScriptError: Error {
    
    case noInputTarget
    case noOutputTarget
    
    
    var localizedDescription: String {
        
        switch self {
        case .noInputTarget:
            return NSLocalizedString("No document to get input.", comment: "")
        case .noOutputTarget:
            return NSLocalizedString("No document to put output.", comment: "")
        }
    }
    
}



// MARK: - ScriptToken

private protocol ScriptToken {
    
    static var token: String { get }
    
    init?(rawValue: String)
    
}

private extension ScriptToken {
    
    /// read type from script
    init?(scanning script: String) {
        
        let pattern = "%%%\\{" + Self.token + "=" + "(.+)" + "\\}%%%"
        let regex = try! NSRegularExpression(pattern: pattern)
        
        guard let result = regex.firstMatch(in: script, range: script.nsRange) else { return nil }
        
        let type = (script as NSString).substring(with: result.rangeAt(1))
        
        self.init(rawValue: type)
    }
    
}



// MARK: Private Functions

fileprivate func writeToConsole(message: String, scriptName: String) {
    
    DispatchQueue.main.async {
        ConsolePanelController.shared.showWindow(nil)
        ConsolePanelController.shared.append(message: message, title: scriptName)
    }
}
