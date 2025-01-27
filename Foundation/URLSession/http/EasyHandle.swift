// Foundation/URLSession/EasyHandle.swift - URLSession & libcurl
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
/// libcurl *easy handle* wrapper.
/// These are libcurl helpers for the URLSession API code.
/// - SeeAlso: https://curl.haxx.se/libcurl/c/
/// - SeeAlso: URLSession.swift
///
// -----------------------------------------------------------------------------

import CoreFoundation
import Dispatch



/// Minimal wrapper around the [curl easy interface](https://curl.haxx.se/libcurl/c/)
///
/// An *easy handle* manages the state of a transfer inside libcurl.
///
/// As such the easy handle's responsibility is implementing the HTTP
/// protocol while the *multi handle* is in charge of managing sockets and
/// reading from / writing to these sockets.
///
/// An easy handle is added to a multi handle in order to associate it with
/// an actual socket. The multi handle will then feed bytes into the easy
/// handle and read bytes from the easy handle. But this process is opaque
/// to use. It is further worth noting, that with HTTP/1.1 persistent
/// connections and with HTTP/2 there's a 1-to-many relationship between
/// TCP streams and HTTP transfers / easy handles. A single TCP stream and
/// its socket may be shared by multiple easy handles.
///
/// A single HTTP request-response exchange (refered to here as a
/// *transfer*) corresponds directly to an easy handle. Hence anything that
/// needs to be configured for a specific transfer (e.g. the URL) will be
/// configured on an easy handle.
///
/// A single `URLSessionTask` may do multiple, sonecutive transfers, and
/// as a result it will have to reconfigure it's easy handle between
/// transfers. An easy handle can be re-used once its transfer has
/// completed.
///
/// - Note: All code assumes that it is being called on a single thread /
/// `Dispatch` only -- it is intentionally **not** thread safe.
internal final class _EasyHandle {
    let rawHandle = CFURLSessionEasyHandleInit()
    weak var delegate: _EasyHandleDelegate?
    fileprivate var headerList: _CurlStringList?
    fileprivate var pauseState: _PauseState = []
    internal var timeoutTimer: _TimeoutSource!
    internal lazy var errorBuffer = [UInt8](repeating: 0, count: Int(CFURLSessionEasyErrorSize))
    
    fileprivate let nsURLAuthMethodsToCURL = [
        NSURLAuthenticationMethodHTTPBasic : CFURLSessionOptionAUTH_BASIC,
        NSURLAuthenticationMethodHTTPDigest : CFURLSessionOptionAUTH_DIGEST,
        NSURLAuthenticationMethodNTLM : CFURLSessionOptionAUTH_NTLM,
        NSURLAuthenticationMethodNegotiate: CFURLSessionOptionAUTH_NEGOTIATE
    ]
    
    init(delegate: _EasyHandleDelegate) {
        self.delegate = delegate
        setupCallbacks()
    }
    deinit {
        CFURLSessionEasyHandleDeinit(rawHandle)
    }
}

extension _EasyHandle: Equatable {}
    internal func ==(lhs: _EasyHandle, rhs: _EasyHandle) -> Bool {
        return lhs.rawHandle == rhs.rawHandle
}

extension _EasyHandle {
    enum _Action {
        case abort
        case proceed
        case pause
    }
    enum _WriteBufferResult {
        case abort
        case pause
        /// Write the given number of bytes into the buffer
        case bytes(Int)
    }
}

internal extension _EasyHandle {
    func completedTransfer(withError error: NSError?) {
        delegate?.transferCompleted(withError: error)
    }
}
internal protocol _EasyHandleDelegate: class {
    /// Handle data read from the network.
    /// - returns: the action to be taken: abort, proceed, or pause.
    func didReceive(data: Data) -> _EasyHandle._Action
    /// Handle header data read from the network.
    /// - returns: the action to be taken: abort, proceed, or pause.
    func didReceive(headerData data: Data, contentLength: Int64) -> _EasyHandle._Action
    /// Fill a buffer with data to be sent.
    ///
    /// - parameter data: The buffer to fill
    /// - returns: the number of bytes written to the `data` buffer, or `nil` to stop the current transfer immediately.
    func fill(writeBuffer buffer: UnsafeMutableBufferPointer<Int8>) -> _EasyHandle._WriteBufferResult
    /// The transfer for this handle completed.
    /// - parameter error: An NSError, or `nil` if no error occured.
    func transferCompleted(withError error: NSError?)
    /// Seek the input stream to the given position
    func seekInputStream(to position: UInt64) throws
    /// Gets called during the transfer to update progress.
    func updateProgressMeter(with propgress: _EasyHandle._Progress)
}
extension _EasyHandle {
    func set(verboseModeOn flag: Bool) {
        try! CFURLSession_easy_setopt_long(rawHandle, CFURLSessionOptionVERBOSE, flag ? 1 : 0).asError()
    }
    /// - SeeAlso: https://curl.haxx.se/libcurl/c/CFURLSessionOptionDEBUGFUNCTION.html
    func set(debugOutputOn flag: Bool, task: URLSessionTask) {
        if flag {
            try! CFURLSession_easy_setopt_ptr(rawHandle, CFURLSessionOptionDEBUGDATA, UnsafeMutableRawPointer(Unmanaged.passUnretained(task).toOpaque())).asError()
            try! CFURLSession_easy_setopt_dc(rawHandle, CFURLSessionOptionDEBUGFUNCTION, printLibcurlDebug(handle:type:data:size:userInfo:)).asError()
        } else {
            try! CFURLSession_easy_setopt_ptr(rawHandle, CFURLSessionOptionDEBUGDATA, nil).asError()
            try! CFURLSession_easy_setopt_ptr(rawHandle, CFURLSessionOptionDEBUGFUNCTION, nil).asError()
        }
    }
    func set(passHeadersToDataStream flag: Bool) {
        try! CFURLSession_easy_setopt_long(rawHandle, CFURLSessionOptionHEADER, flag ? 1 : 0).asError()
    }
    /// Follow any Location: header that the server sends as part of a HTTP header in a 3xx response
    func set(followLocation flag: Bool) {
        try! CFURLSession_easy_setopt_long(rawHandle, CFURLSessionOptionFOLLOWLOCATION, flag ? 1 : 0).asError()
    }
    /// Switch off the progress meter. It will also prevent the CFURLSessionOptionPROGRESSFUNCTION from getting called.
    func set(progressMeterOff flag: Bool) {
        try! CFURLSession_easy_setopt_long(rawHandle, CFURLSessionOptionNOPROGRESS, flag ? 1 : 0).asError()
    }
    /// Skip all signal handling
    /// - SeeAlso: https://curl.haxx.se/libcurl/c/CURLOPT_NOSIGNAL.html
    func set(skipAllSignalHandling flag: Bool) {
        try! CFURLSession_easy_setopt_long(rawHandle, CFURLSessionOptionNOSIGNAL, flag ? 1 : 0).asError()
    }
    /// Set error buffer for error messages
    /// - SeeAlso: https://curl.haxx.se/libcurl/c/CURLOPT_ERRORBUFFER.html
    func set(errorBuffer buffer: UnsafeMutableBufferPointer<UInt8>?) {
        let buffer = buffer ?? errorBuffer.withUnsafeMutableBufferPointer { $0 }
        try! CFURLSession_easy_setopt_ptr(rawHandle, CFURLSessionOptionERRORBUFFER, buffer.baseAddress).asError()
    }
    /// Request failure on HTTP response >= 400
    func set(failOnHTTPErrorCode flag: Bool) {
        try! CFURLSession_easy_setopt_long(rawHandle, CFURLSessionOptionFAILONERROR, flag ? 1 : 0).asError()
    }
    /// URL to use in the request
    /// - SeeAlso: https://curl.haxx.se/libcurl/c/CURLOPT_URL.html
    func set(url: URL) {
        url.absoluteString.withCString {
            try! CFURLSession_easy_setopt_ptr(rawHandle, CFURLSessionOptionURL, UnsafeMutablePointer(mutating: $0)).asError()
        }
    }
    /// Set allowed protocols
    ///
    /// - Note: This has security implications. Not limiting this, someone could
    /// redirect a HTTP request into one of the many other protocols that libcurl
    /// supports.
    /// - SeeAlso: https://curl.haxx.se/libcurl/c/CURLOPT_PROTOCOLS.html
    /// - SeeAlso: https://curl.haxx.se/libcurl/c/CURLOPT_REDIR_PROTOCOLS.html
    func setAllowedProtocolsToHTTPAndHTTPS() {
        let protocols = (CFURLSessionProtocolHTTP | CFURLSessionProtocolHTTPS)
        try! CFURLSession_easy_setopt_long(rawHandle, CFURLSessionOptionPROTOCOLS, protocols).asError()
        try! CFURLSession_easy_setopt_long(rawHandle, CFURLSessionOptionREDIR_PROTOCOLS, protocols).asError()
#if os(Android)
        // See https://curl.haxx.se/docs/sslcerts.html
        // For SSL on Android you need a "cacert.pem" to be
        // accessible at the path pointed to by this env var.
        // Downloadable here: https://curl.haxx.se/ca/cacert.pem
        if let caInfo = getenv("URLSessionCertificateAuthorityInfoFile")  {
            if String(cString: caInfo) == "INSECURE_SSL_NO_VERIFY" {
                try! CFURLSession_easy_setopt_long(rawHandle, CFURLSessionOptionSSL_VERIFYPEER, 0).asError()
            }
            else {
                try! CFURLSession_easy_setopt_ptr(rawHandle, CFURLSessionOptionCAINFO, caInfo).asError()
            }
        }
#endif
        //TODO: Added in libcurl 7.45.0
        //TODO: Set default protocol for schemeless URLs
        //CURLOPT_DEFAULT_PROTOCOL available only in libcurl 7.45.0
    }
    
    //TODO: Proxy setting, namely CFURLSessionOptionPROXY, CFURLSessionOptionPROXYPORT,
    // CFURLSessionOptionPROXYTYPE, CFURLSessionOptionNOPROXY, CFURLSessionOptionHTTPPROXYTUNNEL, CFURLSessionOptionPROXYHEADER,
    // CFURLSessionOptionHEADEROPT, etc.
    
    /// set preferred receive buffer size
    /// - SeeAlso: https://curl.haxx.se/libcurl/c/CURLOPT_BUFFERSIZE.html
    func set(preferredReceiveBufferSize size: Int) {
        try! CFURLSession_easy_setopt_long(rawHandle, CFURLSessionOptionBUFFERSIZE, min(size, Int(CFURLSessionMaxWriteSize))).asError()
    }
    /// Set custom HTTP headers
    /// - SeeAlso: https://curl.haxx.se/libcurl/c/CURLOPT_HTTPHEADER.html
    func set(customHeaders headers: [String]) {
        let list = _CurlStringList(headers)
        try! CFURLSession_easy_setopt_ptr(rawHandle, CFURLSessionOptionHTTPHEADER, list.asUnsafeMutablePointer).asError()
        // We need to retain the list for as long as the rawHandle is in use.
        headerList = list
    }
    ///TODO: Wait for pipelining/multiplexing. Unavailable on Ubuntu 14.0
    /// - SeeAlso: https://curl.haxx.se/libcurl/c/CURLOPT_PIPEWAIT.html
    
    //TODO: The public API does not allow us to use CFURLSessionOptionSTREAM_DEPENDS / CFURLSessionOptionSTREAM_DEPENDS_E
    // Might be good to add support for it, though.
    
    ///TODO: Set numerical stream weight when CURLOPT_PIPEWAIT is enabled
    /// - Parameter weight: values are clamped to lie between 0 and 1
    /// - SeeAlso: https://curl.haxx.se/libcurl/c/CURLOPT_STREAM_WEIGHT.html
    /// - SeeAlso: http://httpwg.org/specs/rfc7540.html#StreamPriority

    /// Enable automatic decompression of HTTP downloads
    /// - SeeAlso: https://curl.haxx.se/libcurl/c/CURLOPT_ACCEPT_ENCODING.html
    /// - SeeAlso: https://curl.haxx.se/libcurl/c/CURLOPT_HTTP_CONTENT_DECODING.html

    func set(automaticBodyDecompression flag: Bool) {
        if flag {
            "".withCString {
                try! CFURLSession_easy_setopt_ptr(rawHandle, CFURLSessionOptionACCEPT_ENCODING, UnsafeMutableRawPointer(mutating: $0)).asError()
            }
            try! CFURLSession_easy_setopt_long(rawHandle, CFURLSessionOptionHTTP_CONTENT_DECODING, 1).asError()
        } else {
            try! CFURLSession_easy_setopt_ptr(rawHandle, CFURLSessionOptionACCEPT_ENCODING, nil).asError()
            try! CFURLSession_easy_setopt_long(rawHandle, CFURLSessionOptionHTTP_CONTENT_DECODING, 0).asError()
        }
    }
    /// Set request method
    /// - SeeAlso: https://curl.haxx.se/libcurl/c/CURLOPT_CUSTOMREQUEST.html
    func set(requestMethod method: String) {
        method.withCString {
            try! CFURLSession_easy_setopt_ptr(rawHandle, CFURLSessionOptionCUSTOMREQUEST, UnsafeMutableRawPointer(mutating: $0)).asError()
        }
    }
    
    /// Download request without body
    /// - SeeAlso: https://curl.haxx.se/libcurl/c/CURLOPT_NOBODY.html
    func set(noBody flag: Bool) {
        try! CFURLSession_easy_setopt_long(rawHandle, CFURLSessionOptionNOBODY, flag ? 1 : 0).asError()
    }
    /// Enable data upload
    /// - SeeAlso: https://curl.haxx.se/libcurl/c/CURLOPT_UPLOAD.html
    func set(upload flag: Bool) {
        try! CFURLSession_easy_setopt_long(rawHandle, CFURLSessionOptionUPLOAD, flag ? 1 : 0).asError()
    }
    /// Set size of the request body to send
    /// - SeeAlso: https://curl.haxx.se/libcurl/c/CURLOPT_INFILESIZE_LARGE.html
    func set(requestBodyLength length: Int64) {
        try! CFURLSession_easy_setopt_int64(rawHandle, CFURLSessionOptionINFILESIZE_LARGE, length).asError()
    }

    func set(timeout value: Int) {
       try! CFURLSession_easy_setopt_long(rawHandle, CFURLSessionOptionTIMEOUT, value).asError()
    }

    func getTimeoutIntervalSpent() -> Double {
        var timeSpent = Double()
        CFURLSession_easy_getinfo_double(rawHandle, CFURLSessionInfoTOTAL_TIME, &timeSpent)
        return timeSpent / 1000
    }
    
    func set(username: String, password: String) {
        "\(username):\(password)".withCString {
            CFURLSession_easy_setopt_ptr(rawHandle, CFURLSessionOptionUSERPWD, UnsafeMutablePointer(mutating: $0))
        }
    }

    func set(authMethod: String) -> Bool {
        if let method = nsURLAuthMethodsToCURL[authMethod] {
            CFURLSession_easy_setopt_unsigned_long(rawHandle, CFURLSessionOptionHTTPAUTH, method)
            return true
        }

        return false
    }

    func set(trustAllCertificates: Bool) {
        let verifyPeer = trustAllCertificates ? 0 : 1
        let verifyHost = trustAllCertificates ? 0 : 1
        CFURLSession_easy_setopt_long(rawHandle, CFURLSessionOptionSSL_VERIFYPEER, verifyPeer)
        CFURLSession_easy_setopt_long(rawHandle, CFURLSessionOptionSSL_VERIFYHOST, verifyHost)
    }
}

fileprivate func printLibcurlDebug(handle: CFURLSessionEasyHandle, type: CInt, data: UnsafeMutablePointer<Int8>, size: Int, userInfo: UnsafeMutableRawPointer?) -> CInt {
    // C.f. <https://curl.haxx.se/libcurl/c/CURLOPT_DEBUGFUNCTION.html>
    let info = CFURLSessionInfo(value: type)
    let text = data.withMemoryRebound(to: UInt8.self, capacity: size, {
        let buffer = UnsafeBufferPointer<UInt8>(start: $0, count: size)
        return String(utf8Buffer: buffer)
    }) ?? "";

    guard let userInfo = userInfo else { return 0 }
    let task = Unmanaged<URLSessionTask>.fromOpaque(userInfo).takeUnretainedValue()
    printLibcurlDebug(type: info, data: text, task: task)
    return 0
}

fileprivate func printLibcurlDebug(type: CFURLSessionInfo, data: String, task: URLSessionTask) {
    // libcurl sends is data with trailing CRLF which inserts lots of newlines into our output.
    NSLog("[\(task.taskIdentifier)] \(type.debugHeader) \(data.mapControlToPictures)")
}

fileprivate extension String {
    /// Replace control characters U+0000 - U+0019 to Control Pictures U+2400 - U+2419
    var mapControlToPictures: String {
        let d = self.unicodeScalars.map { (u: UnicodeScalar) -> UnicodeScalar in
            switch u.value {
            case 0..<0x20: return UnicodeScalar(u.value + 0x2400)!
            default: return u
            }
        }
        return String(String.UnicodeScalarView(d))
    }
}

extension _EasyHandle {
    /// Send and/or receive pause state for an `EasyHandle`
    struct _PauseState : OptionSet {
        let rawValue: Int8
        init(rawValue: Int8) { self.rawValue = rawValue }
        static let receivePaused = _PauseState(rawValue: 1 << 0)
        static let sendPaused = _PauseState(rawValue: 1 << 1)
    }
}
extension _EasyHandle._PauseState {
    func setState(on handle: _EasyHandle) {
        try! CFURLSessionEasyHandleSetPauseState(handle.rawHandle, contains(.sendPaused) ? 1 : 0, contains(.receivePaused) ? 1 : 0).asError()
    }
}
extension _EasyHandle._PauseState : TextOutputStreamable {
    func write<Target : TextOutputStream>(to target: inout Target) {
        switch (self.contains(.receivePaused), self.contains(.sendPaused)) {
        case (false, false): target.write("unpaused")
        case (true, false): target.write("receive paused")
        case (false, true): target.write("send paused")
        case (true, true): target.write("send & receive paused")
        }
    }
}
extension _EasyHandle {
    /// Pause receiving data.
    ///
    /// - SeeAlso: https://curl.haxx.se/libcurl/c/curl_easy_pause.html
    func pauseReceive() {
        guard !pauseState.contains(.receivePaused) else { return }
        pauseState.insert(.receivePaused)
        pauseState.setState(on: self)
    }
    /// Pause receiving data.
    ///
    /// - Note: Chances are high that delegate callbacks (with pending data)
    /// will be called before this method returns.
    /// - SeeAlso: https://curl.haxx.se/libcurl/c/curl_easy_pause.html
    func unpauseReceive() {
        guard pauseState.contains(.receivePaused) else { return }
        pauseState.remove(.receivePaused)
        pauseState.setState(on: self)
    }
    /// Pause sending data.
    ///
    /// - SeeAlso: https://curl.haxx.se/libcurl/c/curl_easy_pause.html
    func pauseSend() {
        guard !pauseState.contains(.sendPaused) else { return }
        pauseState.insert(.sendPaused)
        pauseState.setState(on: self)
    }
    /// Pause sending data.
    ///
    /// - Note: Chances are high that delegate callbacks (with pending data)
    /// will be called before this method returns.
    /// - SeeAlso: https://curl.haxx.se/libcurl/c/curl_easy_pause.html
    func unpauseSend() {
        guard pauseState.contains(.sendPaused) else { return }
        pauseState.remove(.sendPaused)
        pauseState.setState(on: self)
    }
}

internal extension _EasyHandle {
    /// errno number from last connect failure
    /// - SeeAlso: https://curl.haxx.se/libcurl/c/CURLINFO_OS_ERRNO.html
    var connectFailureErrno: Int {
        var errno = Int()
        try! CFURLSession_easy_getinfo_long(rawHandle, CFURLSessionInfoOS_ERRNO, &errno).asError()
        return errno
    }
}


extension CFURLSessionInfo : Equatable {
    public static func ==(lhs: CFURLSessionInfo, rhs: CFURLSessionInfo) -> Bool {
        return lhs.value == rhs.value
    }
}

extension CFURLSessionInfo {
    public var debugHeader: String {
        switch self {
        case CFURLSessionInfoTEXT:         return "                 "
        case CFURLSessionInfoHEADER_OUT:   return "=> Send header   ";
        case CFURLSessionInfoDATA_OUT:     return "=> Send data     ";
        case CFURLSessionInfoSSL_DATA_OUT: return "=> Send SSL data ";
        case CFURLSessionInfoHEADER_IN:    return "<= Recv header   ";
        case CFURLSessionInfoDATA_IN:      return "<= Recv data     ";
        case CFURLSessionInfoSSL_DATA_IN:  return "<= Recv SSL data ";
        default:                            return "                 "
        }
    }
}
extension _EasyHandle {
    /// the URL a redirect would go to
    /// - SeeAlso: https://curl.haxx.se/libcurl/c/CURLINFO_REDIRECT_URL.html
    var redirectURL: URL? {
        var p: UnsafeMutablePointer<Int8>? = nil
        try! CFURLSession_easy_getinfo_charp(rawHandle, CFURLSessionInfoREDIRECT_URL, &p).asError()
        guard let cstring = p else { return nil }
        guard let s = String(cString: cstring, encoding: String.Encoding.utf8) else { return nil }
        return URL(string: s)
    }
}

fileprivate extension _EasyHandle {
    static func from(callbackUserData userdata: UnsafeMutableRawPointer?) -> _EasyHandle? {
        guard let userdata = userdata else { return nil }
        return Unmanaged<_EasyHandle>.fromOpaque(userdata).takeUnretainedValue()
    }
}

fileprivate extension _EasyHandle {

    func resetTimer() {
        //simply create a new timer with the same queue, timeout and handler
        //this must cancel the old handler and reset the timer
        timeoutTimer = _TimeoutSource(queue: timeoutTimer.queue, milliseconds: timeoutTimer.milliseconds, handler: timeoutTimer.handler)
    }

    /// Forward the libcurl callbacks into Swift methods
    func setupCallbacks() {
        // write
        try! CFURLSession_easy_setopt_ptr(rawHandle, CFURLSessionOptionWRITEDATA, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())).asError()
        
        try! CFURLSession_easy_setopt_wc(rawHandle, CFURLSessionOptionWRITEFUNCTION) { (data: UnsafeMutablePointer<Int8>, size: Int, nmemb: Int, userdata: UnsafeMutableRawPointer?) -> Int in
            guard let handle = _EasyHandle.from(callbackUserData: userdata) else { return 0 }
            defer {
                handle.resetTimer()
            }
            return handle.didReceive(data: data, size: size, nmemb: nmemb)
        }.asError()
        
        // read
        try! CFURLSession_easy_setopt_ptr(rawHandle, CFURLSessionOptionREADDATA, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())).asError()
        try! CFURLSession_easy_setopt_wc(rawHandle, CFURLSessionOptionREADFUNCTION) { (data: UnsafeMutablePointer<Int8>, size: Int, nmemb: Int, userdata: UnsafeMutableRawPointer?) -> Int in
            guard let handle = _EasyHandle.from(callbackUserData: userdata) else { return 0 }
            defer {
                handle.resetTimer()
            }
            return handle.fill(writeBuffer: data, size: size, nmemb: nmemb)
        }.asError()
         
        // header
        try! CFURLSession_easy_setopt_ptr(rawHandle, CFURLSessionOptionHEADERDATA, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())).asError()
        try! CFURLSession_easy_setopt_wc(rawHandle, CFURLSessionOptionHEADERFUNCTION) { (data: UnsafeMutablePointer<Int8>, size: Int, nmemb: Int, userdata: UnsafeMutableRawPointer?) -> Int in
            guard let handle = _EasyHandle.from(callbackUserData: userdata) else { return 0 }
            defer {
                handle.resetTimer()
            }
            var length = Double()
            try! CFURLSession_easy_getinfo_double(handle.rawHandle, CFURLSessionInfoCONTENT_LENGTH_DOWNLOAD, &length).asError()
            return handle.didReceive(headerData: data, size: size, nmemb: nmemb, contentLength: length)
        }.asError()

        // socket options
        try! CFURLSession_easy_setopt_ptr(rawHandle, CFURLSessionOptionSOCKOPTDATA, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())).asError()
        try! CFURLSession_easy_setopt_sc(rawHandle, CFURLSessionOptionSOCKOPTFUNCTION) { (userdata: UnsafeMutableRawPointer?, fd: CInt, type: CFURLSessionSocketType) -> CInt in
            guard let handle = _EasyHandle.from(callbackUserData: userdata) else { return 0 }
            guard type == CFURLSessionSocketTypeIPCXN else { return 0 }
            do {
                try handle.setSocketOptions(for: fd)
                return 0
            } catch {
                return 1
            }
        }.asError()
        // seeking in input stream
        try! CFURLSession_easy_setopt_ptr(rawHandle, CFURLSessionOptionSEEKDATA, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())).asError()
        try! CFURLSession_easy_setopt_seek(rawHandle, CFURLSessionOptionSEEKFUNCTION, { (userdata, offset, origin) -> Int32 in
            guard let handle = _EasyHandle.from(callbackUserData: userdata) else { return CFURLSessionSeekFail }
            return handle.seekInputStream(offset: offset, origin: origin)
        }).asError()
        
        // progress
        
        try! CFURLSession_easy_setopt_long(rawHandle, CFURLSessionOptionNOPROGRESS, 0).asError()
        
        try! CFURLSession_easy_setopt_ptr(rawHandle, CFURLSessionOptionPROGRESSDATA, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())).asError()
        
        try! CFURLSession_easy_setopt_tc(rawHandle, CFURLSessionOptionXFERINFOFUNCTION, { (userdata: UnsafeMutableRawPointer?, dltotal :Int64, dlnow: Int64, ultotal: Int64, ulnow: Int64) -> Int32 in
            guard let handle = _EasyHandle.from(callbackUserData: userdata) else { return -1 }
            handle.updateProgressMeter(with: _Progress(totalBytesSent: ulnow, totalBytesExpectedToSend: ultotal, totalBytesReceived: dlnow, totalBytesExpectedToReceive: dltotal))
            return 0
        }).asError()

    }
    /// This callback function gets called by libcurl when it receives body
    /// data.
    ///
    /// - SeeAlso: <https://curl.haxx.se/libcurl/c/CURLOPT_WRITEFUNCTION.html>
    func didReceive(data: UnsafeMutablePointer<Int8>, size: Int, nmemb: Int) -> Int {
        let d: Int = {
            let buffer = Data(bytes: data, count: size*nmemb)
            switch delegate?.didReceive(data: buffer) {
            case .some(.proceed): return size * nmemb
            case .some(.abort): return 0
            case .some(.pause):
                pauseState.insert(.receivePaused)
                return Int(CFURLSessionWriteFuncPause)
            case .none:
                /* the delegate disappeared */
                return 0
            }
        }()
        return d
    }
    /// This callback function gets called by libcurl when it receives header
    /// data.
    ///
    /// - SeeAlso: <https://curl.haxx.se/libcurl/c/CURLOPT_HEADERFUNCTION.html>
    func didReceive(headerData data: UnsafeMutablePointer<Int8>, size: Int, nmemb: Int, contentLength: Double) -> Int {
        let d: Int = {
            let buffer = Data(bytes: data, count: size*nmemb)
            switch delegate?.didReceive(headerData: buffer, contentLength: Int64(contentLength)) {
            case .some(.proceed): return size * nmemb
            case .some(.abort): return 0
            case .some(.pause):
                pauseState.insert(.receivePaused)
                return Int(CFURLSessionWriteFuncPause)
            case .none:
                /* the delegate disappeared */
                return 0
            }
        }()
        return d
    }
    /// This callback function gets called by libcurl when it wants to send data
    /// it to the network.
    ///
    /// - SeeAlso: <https://curl.haxx.se/libcurl/c/CURLOPT_READFUNCTION.html>
    func fill(writeBuffer data: UnsafeMutablePointer<Int8>, size: Int, nmemb: Int) -> Int {
        let d: Int = {
            let buffer = UnsafeMutableBufferPointer(start: data, count: size * nmemb)
            switch delegate?.fill(writeBuffer: buffer) {
            case .some(.pause):
                pauseState.insert(.sendPaused)
                return Int(CFURLSessionReadFuncPause)
            case .some(.abort):
                return Int(CFURLSessionReadFuncAbort)
            case .some(.bytes(let length)):
                return length 
            case .none:
                /* the delegate disappeared */
                return Int(CFURLSessionReadFuncAbort)
            }
        }()
        return d
    }
    
    func setSocketOptions(for fd: CInt) throws {
        //TODO: At this point we should call setsockopt(2) to set the QoS on
        // the socket based on the QoS of the request.
        //
        // On Linux this can be done with IP_TOS. But there's both IntServ and
        // DiffServ.
        //
        // Not sure what Darwin uses.
        //
        // C.f.:
        //     <https://en.wikipedia.org/wiki/Type_of_service>
        //     <https://en.wikipedia.org/wiki/Quality_of_service>
    }
    func updateProgressMeter(with propgress: _Progress) {
        delegate?.updateProgressMeter(with: propgress)
    }
    
    func seekInputStream(offset: Int64, origin: CInt) -> CInt {
        let d: Int32 = {
            /// libcurl should only use SEEK_SET
            guard origin == SEEK_SET else { fatalError("Unexpected 'origin' in seek.") }
            do {
                if let delegate = delegate {
                    try delegate.seekInputStream(to: UInt64(offset))
                    return CFURLSessionSeekOk
                } else {
                    return CFURLSessionSeekCantSeek
                }
            } catch {
                return CFURLSessionSeekCantSeek
            }
        }()
        return d
    }
}

extension _EasyHandle {
    /// The progress of a transfer.
    ///
    /// The number of bytes that we expect to download and upload, and the
    /// number of bytes downloaded and uploaded so far.
    ///
    /// Unknown values will be set to zero. E.g. if the number of bytes
    /// expected to be downloaded is unknown, `totalBytesExpectedToReceive`
    /// will be zero.
    struct _Progress {
        let totalBytesSent: Int64
        let totalBytesExpectedToSend: Int64
        let totalBytesReceived: Int64
        let totalBytesExpectedToReceive: Int64
    }
}

extension _EasyHandle {
    /// A simple wrapper / helper for libcurl’s `slist`.
    ///
    /// It's libcurl's way to represent an array of strings.
    internal class _CurlStringList {
        fileprivate var rawList: OpaquePointer? = nil
        init() {}
        init(_ strings: [String]) {
            strings.forEach { append($0) }
        }
        deinit {
            CFURLSessionSListFreeAll(rawList)
        }
    }
}
extension _EasyHandle._CurlStringList {
    func append(_ string: String) {
        string.withCString {
            rawList = CFURLSessionSListAppend(rawList, $0)
        }
    }
    var asUnsafeMutablePointer: UnsafeMutableRawPointer? {
        return rawList.map{ UnsafeMutableRawPointer($0) }
    }
}

extension CFURLSessionEasyCode : Equatable {
    public static func ==(lhs: CFURLSessionEasyCode, rhs: CFURLSessionEasyCode) -> Bool {
        return lhs.value == rhs.value
    }
}
extension CFURLSessionEasyCode : Error {
    public var _domain: String { return "libcurl.Easy" }
    public var _code: Int { return Int(self.value) }
}
internal extension CFURLSessionEasyCode {
    func asError() throws {
        if self == CFURLSessionEasyCodeOK { return }
        throw self
    }
}
