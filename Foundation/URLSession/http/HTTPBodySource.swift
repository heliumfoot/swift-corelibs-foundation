// Foundation/URLSession/HTTPBodySource.swift - URLSession & libcurl
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2016 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
// -----------------------------------------------------------------------------
///
/// These are libcurl helpers for the URLSession API code.
/// - SeeAlso: https://curl.haxx.se/libcurl/c/
/// - SeeAlso: URLSession.swift
///
// -----------------------------------------------------------------------------

import CoreFoundation
import Dispatch


/// Turn `NSData` into `dispatch_data_t`
internal func createDispatchData(_ data: Data) -> DispatchData {
    //TODO: Avoid copying data
    let buffer = UnsafeRawBufferPointer(start: data._backing.bytes,
                                        count: data.count)
    return DispatchData(bytes: buffer)
}

/// Copy data from `dispatch_data_t` into memory pointed to by an `UnsafeMutableBufferPointer`.
internal func copyDispatchData<T>(_ data: DispatchData, infoBuffer buffer: UnsafeMutableBufferPointer<T>) {
    precondition(data.count <= (buffer.count * MemoryLayout<T>.size))
    _ = data.copyBytes(to: buffer)
}

/// Split `dispatch_data_t` into `(head, tail)` pair.
internal func splitData(dispatchData data: DispatchData, atPosition position: Int) -> (DispatchData,DispatchData) {
    return (data.subdata(in: 0..<position), data.subdata(in: position..<data.count))
}

/// A (non-blocking) source for HTTP body data.
internal protocol _HTTPBodySource: class {
    /// Get the next chunck of data.
    ///
    /// - Returns: `.data` until the source is exhausted, at which point it will
    /// return `.done`. Since this is non-blocking, it will return `.retryLater`
    /// if no data is available at this point, but will be available later.
    func getNextChunk(withLength length: Int) -> _HTTPBodySourceDataChunk

    func seekTo(to position: UInt64) throws
}
internal enum _HTTPBodySourceDataChunk {
    case data(DispatchData)
    /// The source is depleted.
    case done
    /// Retry later to get more data.
    case retryLater
    case error
}
enum _HTTPBodySourceError: Error {
    case cannotSeek
}

/// A HTTP body data source backed by `dispatch_data_t`.
internal final class _HTTPBodyDataSource {
    var data: DispatchData!
    var originalData: DispatchData!
    init(data: DispatchData) {
        self.data = data
        self.originalData = data
    }
}


extension _HTTPBodyDataSource: _HTTPBodySource {
    enum _Error : Error {
        case unableToRewindData
    }

    func rewind() {
        data = originalData
    }


    func seekTo(to position: UInt64) throws {
        if position >= originalData.count {
            throw _HTTPBodySourceError.cannotSeek
        }

        rewind()
        data = data.subdata(in: Int(position)..<data.count)
    }

    func getNextChunk(withLength length: Int) -> _HTTPBodySourceDataChunk {
        let remaining = data.count
        if remaining == 0 {
            return .done
        } else if remaining <= length {
            let r: DispatchData! = data
            data = DispatchData.empty 
            return .data(r)
        } else {
            let (chunk, remainder) = splitData(dispatchData: data, atPosition: length)
            data = remainder
            return .data(chunk)
        }
    }
}

/// A HTTP body data source backed by InputStream.
internal final class _HTTPBodyStreamSource {
    let inputStream: InputStream
    
    init(inputStream: InputStream ) {
        self.inputStream = inputStream
    }
}

extension _HTTPBodyStreamSource: _HTTPBodySource {
    func seekTo(to position: UInt64) throws {
        // You need manually recreate or extend an InputStream, it cannot done by general InputStream
        throw _HTTPBodySourceError.cannotSeek
    }
    func getNextChunk(withLength length: Int) -> _HTTPBodySourceDataChunk {
        if inputStream.hasBytesAvailable {
            let buffer = UnsafeMutableRawBufferPointer.allocate(count: length)
            guard let pointer = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                buffer.deallocate()
                return .error
            }
            let readBytes = self.inputStream.read(pointer, maxLength: length)
            if readBytes > 0 {
                let dispatchData = DispatchData(bytesNoCopy: UnsafeRawBufferPointer(buffer), deallocator: .free)
                return .data(dispatchData.subdata(in: 0 ..< readBytes))                
            }
            else if readBytes == 0 {
                buffer.deallocate()
                return .done
            }
            else {
                buffer.deallocate()
                return .error
            }
        }
        else {
            return .done
        }
    }
}

/// A HTTP body data source backed by a file.
///
/// This allows non-blocking streaming of file data to the remote server.
///
/// The source reads data using a `dispatch_io_t` channel, and hence reading
/// file data is non-blocking. It has a local buffer that it fills as calls
/// to `getNextChunk(withLength:)` drain it.
///
/// - Note: Calls to `getNextChunk(withLength:)` and callbacks from libdispatch
/// should all happen on the same (serial) queue, and hence this code doesn't
/// have to be thread safe.
internal final class _HTTPBodyFileSource {
    fileprivate let fileURL: URL
    fileprivate let channel: DispatchIO 
    fileprivate let workQueue: DispatchQueue 
    fileprivate let dataAvailableHandler: () -> Void
    fileprivate var hasActiveReadHandler = false
    fileprivate var availableChunk: _Chunk = .empty
    /// Create a new data source backed by a file.
    ///
    /// - Parameter fileURL: the file to read from
    /// - Parameter workQueue: the queue that it's safe to call
    ///     `getNextChunk(withLength:)` on, and that the `dataAvailableHandler`
    ///     will be called on.
    /// - Parameter dataAvailableHandler: Will be called when data becomes
    ///     available. Reading data is done in a non-blocking way, such that
    ///     no data may be available even if there's more data in the file.
    ///     if `getNextChunk(withLength:)` returns `.retryLater`, this handler
    ///     will be called once data becomes available.
    init(fileURL: URL, workQueue: DispatchQueue, dataAvailableHandler: @escaping () -> Void) {
        guard fileURL.isFileURL else { fatalError("The body data URL must be a file URL.") }
        self.fileURL = fileURL
        self.workQueue = workQueue
        self.dataAvailableHandler = dataAvailableHandler
        var fileSystemRepresentation: UnsafePointer<Int8>! = nil
        fileURL.withUnsafeFileSystemRepresentation {
            fileSystemRepresentation = $0
        }
        guard let channel = DispatchIO(type: .stream, path: fileSystemRepresentation,
                                       oflag: O_RDONLY, mode: 0, queue: workQueue,
                                       cleanupHandler: {_ in }) else {
            fatalError("Cant create DispatchIO channel")
        }
        self.channel = channel
        self.channel.setLimit(highWater: CFURLSessionMaxWriteSize)
    }

    fileprivate enum _Chunk {
        /// Nothing has been read, yet
        case empty
        /// An error has occured while reading
        case errorDetected(Int)
        /// Data has been read
        case data(DispatchData)
        /// All data has been read from the file (EOF).
        case done(DispatchData?)
    }
}

fileprivate extension _HTTPBodyFileSource {
    fileprivate var desiredBufferLength: Int { return 3 * CFURLSessionMaxWriteSize }
    /// Enqueue a dispatch I/O read to fill the buffer.
    ///
    /// - Note: This is a no-op if the buffer is full, or if a read operation
    /// is already enqueued.
    fileprivate func readNextChunk() {
        // libcurl likes to use a buffer of size CFURLSessionMaxWriteSize, we'll
        // try to keep 3 x of that around in the `chunk` buffer.
        guard availableByteCount < desiredBufferLength else { return }
        guard !hasActiveReadHandler else { return } // We're already reading
        hasActiveReadHandler = true
        
        let lengthToRead = desiredBufferLength - availableByteCount
        channel.read(offset: 0, length: lengthToRead, queue: workQueue) { (done: Bool, data: DispatchData?, errno: Int32) in
            let wasEmpty = self.availableByteCount == 0
            self.hasActiveReadHandler = !done
            
            switch (done, data, errno) {
            case (true, _, errno) where errno != 0:
                self.availableChunk = .errorDetected(Int(errno))
            case (true, .some(let d), 0) where d.isEmpty:
                self.append(data: d, endOfFile: true)
            case (true, .some(let d), 0):
                self.append(data: d, endOfFile: false)
            case (false, .some(let d), 0):
                self.append(data: d, endOfFile: false)
            default:
                fatalError("Invalid arguments to read(3) callback.")
            }
            
            if wasEmpty && (0 < self.availableByteCount) {
                self.dataAvailableHandler()
            }
        }
    }

    fileprivate func append(data: DispatchData, endOfFile: Bool) {
        switch availableChunk {
        case .empty:
            availableChunk = endOfFile ? .done(data) : .data(data)
        case .errorDetected:
            break
        case .data(var oldData):
            oldData.append(data)
            availableChunk = endOfFile ? .done(oldData) : .data(oldData)
        case .done:
            fatalError("Trying to append data, but end-of-file was already detected.")
        }
    }

    fileprivate var availableByteCount: Int {
        switch availableChunk {
        case .empty: return 0
        case .errorDetected: return 0
        case .data(let d): return d.count
        case .done(.some(let d)): return d.count
        case .done(.none): return 0
        }
    }
}

extension _HTTPBodyFileSource : _HTTPBodySource {
    func seekTo(to position: UInt64) throws {
        throw _HTTPBodySourceError.cannotSeek
    }
    
    func getNextChunk(withLength length: Int) -> _HTTPBodySourceDataChunk {    
        switch availableChunk {
        case .empty:
            readNextChunk()
            return .retryLater
        case .errorDetected:
            return .error
        case .data(let data):
            let l = min(length, data.count)
            let (head, tail) = splitData(dispatchData: data, atPosition: l)
            
            availableChunk = tail.isEmpty ? .empty : .data(tail)
            readNextChunk()
            
            if head.isEmpty {
                return .retryLater
            } else {
                return .data(head)
            }
        case .done(.some(let data)):
            let l = min(length, data.count)
            let (head, tail) = splitData(dispatchData: data, atPosition: l)
            availableChunk = tail.isEmpty ? .done(nil) : .done(tail)
            if head.isEmpty {
                return .done
            } else {
                return .data(head)
            }
        case .done(.none):
            return .done
        }
    }
}
