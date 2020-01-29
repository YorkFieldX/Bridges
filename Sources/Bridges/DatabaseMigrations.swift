//
//  DatabaseMigrations.swift
//  Bridges
//
//  Created by Mihael Isaev on 28.01.2020.
//

import Foundation
import Logging
import NIO

public class BridgeDatabaseMigrations<B: Bridgeable> {
    var migrations: [AnyMigration.Type] = []
    let bridge: B
    let db: DatabaseIdentifier
    
    public func add(_ migration: AnyMigration.Type) {
        migrations.append(migration)
    }
    
    public init(_ bridge: B, db: DatabaseIdentifier) {
        self.bridge = bridge
        self.db = db
    }
    
    struct Migrations: Table {
        static var name: String { "migrations" }
        
        @Column("id")
        var id: Int64
        
        @Column("name")
        var name: String
        
        @Column("batch")
        var batch: Int
        
        struct Create: TableMigration {
            typealias Table = Migrations
            
            static func prepare(on conn: BridgeConnection) -> EventLoopFuture<Void> {
                createBuilder
                    .checkIfNotExists()
                    .column(\.$id, .bigserial, .primaryKey)
                    .column(\.$name, .text, .unique)
                    .column(\.$batch, .int)
                    .execute(on: conn)
            }
            
            static func revert(on conn: BridgeConnection) -> EventLoopFuture<Void> {
                dropBuilder.checkIfExists().execute(on: conn)
            }
        }
    }
    
    public func migrate() -> EventLoopFuture<Void> {
        bridge.transaction(to: db) { conn in
            Migrations.Create.prepare(on: conn).flatMap {
                let query = SwifQL.select(Migrations.table.*).from(Migrations.table).prepare(conn.dialect).plain
                return conn.query(raw: query, decoding: Migrations.self).flatMap { completedMigrations in
                    let batch = completedMigrations.map { $0.batch }.max() ?? 0
                    var migrations = self.migrations
                    migrations.removeAll { m in completedMigrations.contains { $0.name == m.name } }
                    return migrations.map { migration in
                        {
                            migration.prepare(on: conn).flatMap {
                                SwifQL
                                    .insertInto(Migrations.table, fields: Path.Column("name"), Path.Column("batch"))
                                    .values
                                    .values(migration.name, batch + 1)
                                    .execute(on: conn)
                            }
                        }
                    }.flatten(on: conn.eventLoop)
                }
            }
        }
    }

    public func revertLast() -> EventLoopFuture<Void> {
        bridge.transaction(to: db) {
            self._revertLast(on: $0).transform(to: ())
        }
    }
    
    private func _revertLast(on conn: BridgeConnection) -> EventLoopFuture<Bool> {
        let query = SwifQL.select(Migrations.table.*).from(Migrations.table).prepare(conn.dialect).plain
        return conn.query(raw: query, decoding: Migrations.self).flatMap { completedMigrations in
            guard let lastBatch = completedMigrations.map({ $0.batch }).max()
                else { return conn.eventLoop.future(false) }
            let migrationsToRevert = completedMigrations.filter { $0.batch == lastBatch }
            var migrations = self.migrations
            migrations.removeAll { m in migrationsToRevert.contains { $0.name != m.name } }
            return migrations.map { migration in
                {
                    migration.revert(on: conn).flatMap {
                        SwifQL
                            .delete(from: Migrations.table)
                            .where(Path.Column("name") == migration.name)
                            .execute(on: conn)
                    }
                }
            }.flatten(on: conn.eventLoop).transform(to: true)
        }
    }
    
    public func revertAll() -> EventLoopFuture<Void> {
        bridge.transaction(to: db) { conn in
            let promise = conn.eventLoop.makePromise(of: Void.self)
            func revert() {
                self._revertLast(on: conn).whenComplete { res in
                    switch res {
                    case .success(let reverted):
                        if reverted {
                            revert()
                        } else {
                            promise.succeed(())
                        }
                    case .failure(let error):
                        promise.fail(error)
                    }
                }
            }
            revert()
            return promise.futureResult
        }
    }
}

// TODO: implement migration lock
//Notes about locks
//
//A lock system is there to prevent multiple processes from running the same migration batch in the same time. When a batch of migrations is about to be run, the migration system first tries to get a lock using a SELECT ... FOR UPDATE statement (preventing race conditions from happening). If it can get a lock, the migration batch will run. If it can't, it will wait until the lock is released.
//
//Please note that if your process unfortunately crashes, the lock will have to be manually removed in order to let migrations run again. The locks are saved in a table called "tableName_lock"; it has a column called is_locked that you need to set to 0 in order to release the lock. The index column in the lock table exists for compatibility with some database clusters that require a primary key, but is otherwise unused.