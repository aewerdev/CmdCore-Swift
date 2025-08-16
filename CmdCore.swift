//
//  CmdCore.swift
//  WUtils
//
//  Created by aewerdev on 8/16/25.
//

import Foundation

class Command {
    /// The keyword used to invoke the command (e.g., "greet").
    let keyword: String
    
    /// A brief description of what the command does.
    let description: String
    
    /// The template string that defines the expected arguments.
    let argumentTemplate: String
    
    /// The block of code to execute when the command is run.
    /// It receives a dictionary of parsed arguments.
    let action: ([String: Any]) -> Void

    /// Initializes a new command.
    /// - Parameters:
    ///   - keyword: The word to type to run the command.
    ///   - description: A short explanation for help menus.
    ///   - argumentTemplate: A string defining the arguments (e.g., "&string name &int age").
    ///   - action: The code that runs when the command is invoked.
    init(keyword: String, description: String, argumentTemplate: String, action: @escaping ([String: Any]) -> Void) {
        self.keyword = keyword
        self.description = description
        self.argumentTemplate = argumentTemplate
        self.action = action
    }
}

class CommandEnvironment {
    
    // MARK: - Nested Helper Types
    
    /// Custom errors for clear feedback during parsing.
    enum CommandError: Error, CustomStringConvertible {
        case invalidTemplate(String)
        case argumentMismatch(String)
        case typeConversionFailed(String)
        case invalidExpression(String)
        case commandNotFound(String)
        case invalidInputFormat(String)

        var description: String {
            switch self {
            case .invalidTemplate(let r): return "Invalid Template: \(r)"
            case .argumentMismatch(let r): return "Argument Mismatch: \(r)"
            case .typeConversionFailed(let r): return "Type Conversion Failed: \(r)"
            case .invalidExpression(let r): return "Invalid Expression: \(r)"
            case .commandNotFound(let r): return "Command '\(r)' not found."
            case .invalidInputFormat(let r): return "Invalid Format: \(r)"
            }
        }
    }
    
    /// Represents the fundamental data types we can parse.
    private enum ArgumentDataType: String {
        case string, int, float, char
    }

    /// Represents a parsed argument definition from the template string.
    private struct ArgumentDefinition {
        enum ArgType {
            case simple(type: ArgumentDataType)
            case array(sizeExpression: String, elementType: ArgumentDataType?)
        }
        let name: String
        let type: ArgType
    }
    
    // MARK: - Properties
    
    private var commands: [String: Command] = [:]

    // MARK: - Public Methods
    
    /// Registers a new command with the environment.
    public func add(command: Command) {
        commands[command.keyword] = command
    }
    
    /// Parses and executes a command string.
    public func run(input: String) {
        do {
            // 1. Split "kwrd:args" into keyword and the argument string
            guard let colonIndex = input.firstIndex(of: ":") else {
                throw CommandError.invalidInputFormat("Missing ':' separator. Use 'keyword:args'.")
            }
            
            let keyword = String(input[..<colonIndex])
            guard let command = commands[keyword] else {
                throw CommandError.commandNotFound(keyword)
            }

            let argsString = input[input.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
            let rawArgs = argsString.split(separator: " ").map(String.init)
            
            // 2. Parse arguments based on the command's template
            let parsedArgs = try parseArguments(rawArgs: rawArgs, for: command)
            
            // 3. Execute the command's action
            command.action(parsedArgs)
            
        } catch {
            print("Error: \(error)")
        }
    }

    // MARK: - Private Parsing Logic
    
    /// Top-level function to orchestrate argument parsing for a command.
    private func parseArguments(rawArgs: [String], for command: Command) throws -> [String: Any] {
        let definitions = try parseTemplate(from: command.argumentTemplate)
        
        var parsedArgs: [String: Any] = [:]
        var currentArgIndex = 0

        for definition in definitions {
            switch definition.type {
            case .simple(let type):
                guard currentArgIndex < rawArgs.count else {
                    throw CommandError.argumentMismatch("Missing argument for '\(definition.name)'.")
                }
                let rawValue = rawArgs[currentArgIndex]
                parsedArgs[definition.name] = try convert(value: rawValue, to: type, for: definition.name)
                currentArgIndex += 1

            case .array(let sizeExpression, let elementType):
                // Evaluate the array's size
                let size = try evaluateArraySize(from: sizeExpression, with: parsedArgs, for: definition.name)
                
                guard currentArgIndex + size <= rawArgs.count else {
                    throw CommandError.argumentMismatch("Not enough arguments for array '\(definition.name)'. Expected \(size), found \(rawArgs.count - currentArgIndex).")
                }
                
                // Slice the raw arguments for the array
                let arraySlice = rawArgs[currentArgIndex..<(currentArgIndex + size)]
                
                if let elementType = elementType {
                    // Convert each element if a type is specified
                    parsedArgs[definition.name] = try arraySlice.map { try convert(value: $0, to: elementType, for: definition.name) }
                } else {
                    // Otherwise, default to an array of strings
                    parsedArgs[definition.name] = Array(arraySlice)
                }
                currentArgIndex += size
            }
        }
        
        if currentArgIndex < rawArgs.count {
            print("Warning: \(rawArgs.count - currentArgIndex) trailing argument(s) were ignored.")
        }
        
        return parsedArgs
    }
    
    /// Uses Regular Expressions to parse an argument template string into a list of definitions.
    private func parseTemplate(from template: String) throws -> [ArgumentDefinition] {
        var definitions: [ArgumentDefinition] = []
        // Regex: matches patterns like "&type name" or "&array<details> name"
        let pattern = #"&(\w+)(?:<([^>]+)>)?\s+([a-zA-Z0-9_]+)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let matches = regex.matches(in: template, range: NSRange(template.startIndex..<template.endIndex, in: template))

        for match in matches {
            let typeStr = (template as NSString).substring(with: match.range(at: 1))
            let name = (template as NSString).substring(with: match.range(at: 3))

            if typeStr == "array" {
                guard match.range(at: 2).location != NSNotFound else {
                    throw CommandError.invalidTemplate("Array '\(name)' needs size details like <size> or <size, type>.")
                }
                let details = (template as NSString).substring(with: match.range(at: 2)).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                let sizeExpr = String(details[0])
                let elementType = details.count > 1 ? ArgumentDataType(rawValue: String(details[1])) : nil
                if details.count > 1 && elementType == nil {
                     throw CommandError.invalidTemplate("Unknown array element type '\(details[1])' for '\(name)'.")
                }
                definitions.append(ArgumentDefinition(name: name, type: .array(sizeExpression: sizeExpr, elementType: elementType)))
            } else {
                guard let simpleType = ArgumentDataType(rawValue: typeStr) else {
                    throw CommandError.invalidTemplate("Unknown data type '\(typeStr)' for argument '\(name)'.")
                }
                definitions.append(ArgumentDefinition(name: name, type: .simple(type: simpleType)))
            }
        }
        return definitions
    }
    
    /// Evaluates a string to determine an array's size. Supports fixed numbers and dynamic expressions.
    private func evaluateArraySize(from expression: String, with context: [String: Any], for name: String) throws -> Int {
        if let fixedSize = Int(expression) {
            return fixedSize
        }
        
        // Use NSExpression to evaluate formulas like "count * 2"
        let nsExpression = NSExpression(format: expression)
        let numberContext = context.compactMapValues { $0 as? NSNumber }
        
        guard let result = nsExpression.expressionValue(with: numberContext, context: nil) as? NSNumber else {
            throw CommandError.invalidExpression("Could not evaluate array size '\(expression)' for '\(name)'. Ensure all variables are numbers.")
        }
        
        let size = result.intValue
        guard size >= 0 else {
            throw CommandError.argumentMismatch("Calculated array size for '\(name)' is negative (\(size)).")
        }
        return size
    }

    /// Converts a single string value to the specified data type.
    private func convert(value: String, to type: ArgumentDataType, for name: String) throws -> Any {
        switch type {
        case .string:
            return value
        case .int:
            guard let intValue = Int(value) else { throw CommandError.typeConversionFailed("Cannot convert '\(value)' to Int for '\(name)'.") }
            return intValue
        case .float:
            guard let floatValue = Float(value) else { throw CommandError.typeConversionFailed("Cannot convert '\(value)' to Float for '\(name)'.") }
            return floatValue
        case .char:
            guard value.count == 1 else { throw CommandError.typeConversionFailed("Cannot convert '\(value)' to Char for '\(name)'. Must be a single character.") }
            return value.first!
        }
    }
}
