//
//  Model.swift
//  Bridges
//
//  Created by Mihael Isaev on 27.01.2020.
//

import Foundation
import SwifQL

public typealias BridgeTable = Table

public protocol Table: Tableable {
    init ()
}

extension Table {
    var columns: [(String, AnyColumn)] {
        return Mirror(reflecting: self)
            .children
            .compactMap { child in
                guard let label = child.label else {
                    return nil
                }
                guard let property = child.value as? AnyColumn else {
                    return nil
                }
                // remove underscore
                return (String(label.dropFirst()), property)
            }
    }
    
    /// See `Codable`
    
    public init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: TableCodingKey.self)
        try self.columns.forEach { label, property in
            let decoder = TableContainerDecoder(container: container, key: .string(label))
            try property.decode(from: decoder)
        }
    }

    public func encode(to encoder: Encoder) throws {
        let container = encoder.container(keyedBy: TableCodingKey.self)
        try self.columns.forEach { label, property in
            let encoder = ContainerEncoder(container: container, key: .string(label))
            try property.encode(to: encoder)
        }
    }
}

enum TableCodingKey: CodingKey {
    case string(String)
    case int(Int)
    
    var stringValue: String {
        switch self {
        case .int(let int): return String(describing: int)
        case .string(let string): return string
        }
    }
    
    var intValue: Int? {
        switch self {
        case .int(let int): return int
        case .string(let string): return Int(string)
        }
    }
    
    init?(stringValue: String) {
        self = .string(stringValue)
    }
    
    init?(intValue: Int) {
        self = .int(intValue)
    }
}

private struct TableContainerDecoder: Decoder, SingleValueDecodingContainer {
    let container: KeyedDecodingContainer<TableCodingKey>
    let key: TableCodingKey
    
    var codingPath: [CodingKey] {
        self.container.codingPath
    }
    
    var userInfo: [CodingUserInfoKey : Any] {
        [:]
    }
    
    func container<Key>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> where Key : CodingKey {
        try self.container.nestedContainer(keyedBy: Key.self, forKey: self.key)
    }
    
    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        try self.container.nestedUnkeyedContainer(forKey: self.key)
    }
    
    func singleValueContainer() throws -> SingleValueDecodingContainer {
        self
    }
    
    func decode<T>(_ type: T.Type) throws -> T where T : Decodable {
        try self.container.decode(T.self, forKey: self.key)
    }
    
    func decodeNil() -> Bool {
        do {
            return try self.container.decodeNil(forKey: self.key)
        } catch {
            return true
        }
    }
}

private struct ContainerEncoder: Encoder, SingleValueEncodingContainer {
    var container: KeyedEncodingContainer<TableCodingKey>
    let key: TableCodingKey
    
    var codingPath: [CodingKey] {
        self.container.codingPath
    }
    
    var userInfo: [CodingUserInfoKey : Any] {
        [:]
    }
    
    func container<Key>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> where Key : CodingKey {
        var container = self.container
        return container.nestedContainer(keyedBy: Key.self, forKey: self.key)
    }
    
    func unkeyedContainer() -> UnkeyedEncodingContainer {
        var container = self.container
        return container.nestedUnkeyedContainer(forKey: self.key)
    }
    
    func singleValueContainer() -> SingleValueEncodingContainer {
        self
    }
    
    mutating func encode<T>(_ value: T) throws where T : Encodable {
        try self.container.encode(value, forKey: self.key)
    }
    
    mutating func encodeNil() throws {
        try self.container.encodeNil(forKey: self.key)
    }
}
