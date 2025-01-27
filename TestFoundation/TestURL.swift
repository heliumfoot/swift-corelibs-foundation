// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2016 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//


#if DEPLOYMENT_RUNTIME_OBJC || os(Linux)
import Foundation
import XCTest
#else
import SwiftFoundation
import SwiftXCTest
#endif


let kURLTestParsingTestsKey = "ParsingTests"

let kURLTestTitleKey = "In-Title"
let kURLTestUrlKey = "In-Url"
let kURLTestBaseKey = "In-Base"
let kURLTestURLCreatorKey = "In-URLCreator"
let kURLTestPathComponentKey = "In-PathComponent"
let kURLTestPathExtensionKey = "In-PathExtension"

let kURLTestCFResultsKey = "Out-CFResults"
let kURLTestNSResultsKey = "Out-NSResults"

let kNSURLWithStringCreator = "NSURLWithString"
let kCFURLCreateWithStringCreator = "CFURLCreateWithString"
let kCFURLCreateWithBytesCreator = "CFURLCreateWithBytes"
let kCFURLCreateAbsoluteURLWithBytesCreator = "CFURLCreateAbsoluteURLWithBytes"

let kNullURLString = "<null url>"
let kNullString = "<null>"

/// Reads the test data plist file and returns the list of objects
private func getTestData() -> [Any]? {
    let testFilePath = testBundle().url(forResource: "NSURLTestData", withExtension: "plist")
    let data = try! Data(contentsOf: testFilePath!)
    guard let testRoot = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String : Any] else {
        XCTFail("Unable to deserialize property list data")
        return nil
    }
    guard let parsingTests = testRoot![kURLTestParsingTestsKey] as? [Any] else {
        XCTFail("Unable to create the parsingTests dictionary")
        return nil
    }
    return parsingTests
}

class TestURL : XCTestCase {
    static var allTests: [(String, (TestURL) -> () throws -> Void)] {
        return [
            ("test_URLStrings", test_URLStrings),
            ("test_fileURLWithPath_relativeTo", test_fileURLWithPath_relativeTo ),
            // TODO: these tests fail on linux, more investigation is needed
            ("test_fileURLWithPath", test_fileURLWithPath),
            ("test_fileURLWithPath_isDirectory", test_fileURLWithPath_isDirectory),
            ("test_URLByResolvingSymlinksInPath", test_URLByResolvingSymlinksInPath),
            ("test_reachable", test_reachable),
            ("test_copy", test_copy),
            ("test_itemNSCoding", test_itemNSCoding),
            ("test_dataRepresentation", test_dataRepresentation),
        ]
    }
    
    func test_fileURLWithPath_relativeTo() {
        let homeDirectory = NSHomeDirectory()
        XCTAssertNotNil(homeDirectory, "Failed to find home directory")
        let homeURL = URL(fileURLWithPath: homeDirectory, isDirectory: true)
        XCTAssertNotNil(homeURL, "fileURLWithPath:isDirectory: failed")
        XCTAssertEqual(homeDirectory, homeURL.path)

        #if os(OSX)
        let baseURL = URL(fileURLWithPath: homeDirectory, isDirectory: true)
        let relativePath = "Documents"
        #elseif os(Android)
        let baseURL = URL(fileURLWithPath: "/data", isDirectory: true)
        let relativePath = "local"
        #elseif os(Linux)
        let baseURL = URL(fileURLWithPath: "/usr", isDirectory: true)
        let relativePath = "include"
        #endif
        // we're telling fileURLWithPath:isDirectory:relativeTo: Documents is a directory
        let url1 = URL(fileURLWithFileSystemRepresentation: relativePath, isDirectory: true, relativeTo: baseURL)
        XCTAssertNotNil(url1, "fileURLWithPath:isDirectory:relativeTo: failed")
        // we're letting fileURLWithPath:relativeTo: determine Documents is a directory with I/O
        let url2 = URL(fileURLWithPath: relativePath, relativeTo: baseURL)
        XCTAssertNotNil(url2, "fileURLWithPath:relativeTo: failed")
        XCTAssertEqual(url1, url2, "\(url1) was not equal to \(url2)")
        // we're telling fileURLWithPath:relativeTo: Documents is a directory with a trailing slash
        let url3 = URL(fileURLWithPath: relativePath + "/", relativeTo: baseURL)
        XCTAssertNotNil(url3, "fileURLWithPath:relativeTo: failed")
        XCTAssertEqual(url1, url3, "\(url1) was not equal to \(url3)")
    }
    
    /// Returns a URL from the given url string and base
    private func URLWithString(_ urlString : String, baseString : String?) -> URL? {
        if let baseString = baseString {
            let baseURL = URL(string: baseString)
            return URL(string: urlString, relativeTo: baseURL)
        } else {
            return URL(string: urlString)
        }
    }
    
    internal func generateResults(_ url: URL, pathComponent: String?, pathExtension : String?) -> [String : Any] {
        var result = [String : Any]()
        if let pathComponent = pathComponent {
            let newFileURL = url.appendingPathComponent(pathComponent, isDirectory: false)
            result["appendingPathComponent-File"] = newFileURL.relativeString
            result["appendingPathComponent-File-BaseURL"] = newFileURL.baseURL?.relativeString ?? kNullString

            let newDirURL = url.appendingPathComponent(pathComponent, isDirectory: true)
            result["appendingPathComponent-Directory"] = newDirURL.relativeString
            result["appendingPathComponent-Directory-BaseURL"] = newDirURL.baseURL?.relativeString ?? kNullString
        } else if let pathExtension = pathExtension {
            let newURL = url.appendingPathExtension(pathExtension)
            result["appendingPathExtension"] = newURL.relativeString
            result["appendingPathExtension-BaseURL"] = newURL.baseURL?.relativeString ?? kNullString
        } else {
            result["relativeString"] = url.relativeString
            result["baseURLString"] = url.baseURL?.relativeString ?? kNullString
            result["absoluteString"] = url.absoluteString
            result["absoluteURLString"] = url.absoluteURL.relativeString
            result["scheme"] = url.scheme ?? kNullString
            result["host"] = url.host ?? kNullString
            
            result["port"] = url.port ?? kNullString
            result["user"] = url.user ?? kNullString
            result["password"] = url.password ?? kNullString
            result["path"] = url.path
            result["query"] = url.query ?? kNullString
            result["fragment"] = url.fragment ?? kNullString
            result["relativePath"] = url.relativePath
            result["isFileURL"] = url.isFileURL ? "YES" : "NO"
            result["standardizedURL"] = url.standardized.relativeString
            
            result["pathComponents"] = url.pathComponents 
            result["lastPathComponent"] = url.lastPathComponent
            result["pathExtension"] = url.pathExtension
            result["deletingLastPathComponent"] = url.deletingLastPathComponent().relativeString
            result["deletingLastPathExtension"] = url.deletingPathExtension().relativeString
        }
        return result
    }

    internal func compareResults(_ url : URL, expected : [String : Any], got : [String : Any]) -> (Bool, [String]) {
        var differences = [String]()
        for (key, obj) in expected {
            // Skip non-string expected results
            if ["port", "standardizedURL", "pathComponents"].contains(key) {
                continue
            }
            if let expectedValue = obj as? String {
                if let testedValue = got[key] as? String {
                    if expectedValue != testedValue {
                        differences.append(" \(key)  Expected = '\(expectedValue)',  Got = '\(testedValue)'")
                    }
                } else {
                    differences.append(" \(key)  Expected = '\(expectedValue)',  Got = '\(String(describing: got[key]))'")
                }
            } else if let expectedValue = obj as? [String] {
                if let testedValue = got[key] as? [String] {
                    if expectedValue != testedValue {
                        differences.append(" \(key)  Expected = '\(expectedValue)',  Got = '\(testedValue)'")
                    }
                } else {
                    differences.append(" \(key)  Expected = '\(expectedValue)',  Got = '\(String(describing: got[key]))'")
                }
            } else if let expectedValue = obj as? Int {
                if let testedValue = got[key] as? Int {
                    if expectedValue != testedValue {
                        differences.append(" \(key)  Expected = '\(expectedValue)',  Got = '\(testedValue)'")
                    }
                } else {
                    differences.append(" \(key)  Expected = '\(expectedValue)',  Got = '\(String(describing: got[key]))'")
                }
            }
            
        }
        for (key, obj) in got {
            if expected[key] == nil {
                differences.append(" \(key)  Expected = 'nil',  Got = '\(obj)'")
            }
        }
        if differences.count > 0 {
            differences.sort()
            differences.insert(" url:  '\(url)' ", at: 0)
            return (false, differences)
        } else {
            return (true, [])
        }
    }

    func test_URLStrings() {
        for obj in getTestData()! {
            let testDict = obj as! [String: Any]
            let title = testDict[kURLTestTitleKey] as! String
            let inURL = testDict[kURLTestUrlKey]! as! String
            let inBase = testDict[kURLTestBaseKey] as! String?
            let inPathComponent = testDict[kURLTestPathComponentKey] as! String?
            let inPathExtension = testDict[kURLTestPathExtensionKey] as! String?
            let expectedNSResult = testDict[kURLTestNSResultsKey]!
            var url : URL? = nil
            
            switch (testDict[kURLTestURLCreatorKey]! as! String) {
            case kNSURLWithStringCreator:
                url = URLWithString(inURL, baseString: inBase)
            case kCFURLCreateWithStringCreator, kCFURLCreateWithBytesCreator, kCFURLCreateAbsoluteURLWithBytesCreator:
                // TODO: Not supported right now
                continue
            default:
                XCTFail()
            }
            if title == "NSURLWithString-parse-ambiguous-url-001" {
                // TODO: Fix this test
            } else {
                if let url = url {
                        let results = generateResults(url, pathComponent: inPathComponent, pathExtension: inPathExtension)
                        let (isEqual, differences) = compareResults(url, expected: expectedNSResult as! [String: Any], got: results)
                        XCTAssertTrue(isEqual, "\(title): \(differences.joined(separator: "\n"))")
                } else {
                    XCTAssertEqual(expectedNSResult as? String, kNullURLString)
                }
            }
        }
        
    }
    
    static let gBaseTemporaryDirectoryPath = NSTemporaryDirectory()
    static var gBaseCurrentWorkingDirectoryPath : String {
        let count = Int(1024) // MAXPATHLEN is platform specific; this is the lowest common denominator for darwin and most linuxes
        var buf : [Int8] = Array(repeating: 0, count: count)
        getcwd(&buf, count)
        return String(cString: buf)
    }
    static var gRelativeOffsetFromBaseCurrentWorkingDirectory: UInt = 0
    static let gFileExistsName = "TestCFURL_file_exists\(ProcessInfo.processInfo.globallyUniqueString)"
    static let gFileDoesNotExistName = "TestCFURL_file_does_not_exist"
    static let gDirectoryExistsName = "TestCFURL_directory_exists\(ProcessInfo.processInfo.globallyUniqueString)"
    static let gDirectoryDoesNotExistName = "TestCFURL_directory_does_not_exist"
    static let gFileExistsPath = gBaseTemporaryDirectoryPath + gFileExistsName
    static let gFileDoesNotExistPath = gBaseTemporaryDirectoryPath + gFileDoesNotExistName
    static let gDirectoryExistsPath = gBaseTemporaryDirectoryPath + gDirectoryExistsName
    static let gDirectoryDoesNotExistPath = gBaseTemporaryDirectoryPath + gDirectoryDoesNotExistName

    static func setup_test_paths() -> Bool {
        if creat(gFileExistsPath, S_IRWXU) < 0 && errno != EEXIST {
            return false
        }
        if unlink(gFileDoesNotExistPath) != 0 && errno != ENOENT {
            return false
        }
        if mkdir(gDirectoryExistsPath, S_IRWXU) != 0 && errno != EEXIST {
            return false
        }
        if rmdir(gDirectoryDoesNotExistPath) != 0 && errno != ENOENT {
            return false
        }
        
        #if os(Android)
        chdir("/data/local/tmp")
        #endif

        let cwd = FileManager.default.currentDirectoryPath
        let cwdURL = URL(fileURLWithPath: cwd, isDirectory: true)
        // 1 for path separator
        cwdURL.withUnsafeFileSystemRepresentation {
            gRelativeOffsetFromBaseCurrentWorkingDirectory = UInt(strlen($0!) + 1)
        }
        
        
        return true
    }
        
    func test_fileURLWithPath() {
        if !TestURL.setup_test_paths() {
            let error = strerror(errno)!
            XCTFail("Failed to set up test paths: \(String(cString: error))")
        }
        
        // test with file that exists
        var path = TestURL.gFileExistsPath
        var url = NSURL(fileURLWithPath: path)
        XCTAssertFalse(url.hasDirectoryPath, "did not expect URL with directory path: \(url)")
        XCTAssertEqual(path, url.path, "path from file path URL is wrong")
        
        // test with file that doesn't exist
        path = TestURL.gFileDoesNotExistPath
        url = NSURL(fileURLWithPath: path)
        XCTAssertFalse(url.hasDirectoryPath, "did not expect URL with directory path: \(url)")
        XCTAssertEqual(path, url.path, "path from file path URL is wrong")
            
        // test with directory that exists
        path = TestURL.gDirectoryExistsPath
        url = NSURL(fileURLWithPath: path)
        XCTAssertTrue(url.hasDirectoryPath, "expected URL with directory path: \(url)")
        XCTAssertEqual(path, url.path, "path from file path URL is wrong")

        // test with directory that doesn't exist
        path = TestURL.gDirectoryDoesNotExistPath
        url = NSURL(fileURLWithPath: path)
        XCTAssertFalse(url.hasDirectoryPath, "did not expect URL with directory path: \(url)")
        XCTAssertEqual(path, url.path, "path from file path URL is wrong")

        // test with name relative to current working directory
        path = TestURL.gFileDoesNotExistName
        url = NSURL(fileURLWithPath: path)
        XCTAssertFalse(url.hasDirectoryPath, "did not expect URL with directory path: \(url)")
        let fileSystemRep = url.fileSystemRepresentation
        let actualLength = strlen(fileSystemRep)
        // 1 for path separator
        let expectedLength = UInt(strlen(TestURL.gFileDoesNotExistName)) + TestURL.gRelativeOffsetFromBaseCurrentWorkingDirectory
        XCTAssertEqual(UInt(actualLength), expectedLength, "fileSystemRepresentation was too short")
        XCTAssertTrue(strncmp(TestURL.gBaseCurrentWorkingDirectoryPath, fileSystemRep, Int(strlen(TestURL.gBaseCurrentWorkingDirectoryPath))) == 0, "fileSystemRepresentation of base path is wrong")
        let lengthOfRelativePath = Int(strlen(TestURL.gFileDoesNotExistName))
        let relativePath = fileSystemRep.advanced(by: Int(TestURL.gRelativeOffsetFromBaseCurrentWorkingDirectory))
        XCTAssertTrue(strncmp(TestURL.gFileDoesNotExistName, relativePath, lengthOfRelativePath) == 0, "fileSystemRepresentation of file path is wrong")
    }
        
    func test_fileURLWithPath_isDirectory() {
        if !TestURL.setup_test_paths() {
            let error = strerror(errno)!
            XCTFail("Failed to set up test paths: \(String(cString: error))")
        }
        
        // test with file that exists
        var path = TestURL.gFileExistsPath
        var url = NSURL(fileURLWithPath: path, isDirectory: true)
        XCTAssertTrue(url.hasDirectoryPath, "expected URL with directory path: \(url)")
        url = NSURL(fileURLWithPath: path, isDirectory: false)
        XCTAssertFalse(url.hasDirectoryPath, "did not expect URL with directory path: \(url)")
        XCTAssertEqual(path, url.path, "path from file path URL is wrong")
        
        // test with file that doesn't exist
        path = TestURL.gFileDoesNotExistPath
        url = NSURL(fileURLWithPath: path, isDirectory: true)
        XCTAssertTrue(url.hasDirectoryPath, "expected URL with directory path: \(url)")
        url = NSURL(fileURLWithPath: path, isDirectory: false)
        XCTAssertFalse(url.hasDirectoryPath, "did not expect URL with directory path: \(url)")
        XCTAssertEqual(path, url.path, "path from file path URL is wrong")
        
        // test with directory that exists
        path = TestURL.gDirectoryExistsPath
        url = NSURL(fileURLWithPath: path, isDirectory: false)
        XCTAssertFalse(url.hasDirectoryPath, "did not expect URL with directory path: \(url)")
        url = NSURL(fileURLWithPath: path, isDirectory: true)
        XCTAssertTrue(url.hasDirectoryPath, "expected URL with directory path: \(url)")
        XCTAssertEqual(path, url.path, "path from file path URL is wrong")
        
        // test with directory that doesn't exist
        path = TestURL.gDirectoryDoesNotExistPath
        url = NSURL(fileURLWithPath: path, isDirectory: false)
        XCTAssertFalse(url.hasDirectoryPath, "did not expect URL with directory path: \(url)")
        url = NSURL(fileURLWithPath: path, isDirectory: true)
        XCTAssertTrue(url.hasDirectoryPath, "expected URL with directory path: \(url)")
        XCTAssertEqual(path, url.path, "path from file path URL is wrong")
        
        // test with name relative to current working directory
        path = TestURL.gFileDoesNotExistName
        url = NSURL(fileURLWithPath: path, isDirectory: false)
        XCTAssertFalse(url.hasDirectoryPath, "did not expect URL with directory path: \(url)")
        url = NSURL(fileURLWithPath: path, isDirectory: true)
        XCTAssertTrue(url.hasDirectoryPath, "expected URL with directory path: \(url)")
        let fileSystemRep = url.fileSystemRepresentation
        let actualLength = UInt(strlen(fileSystemRep))
        // 1 for path separator
        let expectedLength = UInt(strlen(TestURL.gFileDoesNotExistName)) + TestURL.gRelativeOffsetFromBaseCurrentWorkingDirectory
        XCTAssertEqual(actualLength, expectedLength, "fileSystemRepresentation was too short")
        XCTAssertTrue(strncmp(TestURL.gBaseCurrentWorkingDirectoryPath, fileSystemRep, Int(strlen(TestURL.gBaseCurrentWorkingDirectoryPath))) == 0, "fileSystemRepresentation of base path is wrong")
        let lengthOfRelativePath = Int(strlen(TestURL.gFileDoesNotExistName))
        let relativePath = fileSystemRep.advanced(by: Int(TestURL.gRelativeOffsetFromBaseCurrentWorkingDirectory))
        XCTAssertTrue(strncmp(TestURL.gFileDoesNotExistName, relativePath, lengthOfRelativePath) == 0, "fileSystemRepresentation of file path is wrong")
    }
    
    func test_URLByResolvingSymlinksInPath() {
        let files = [
            NSTemporaryDirectory() + "ABC/test_URLByResolvingSymlinksInPath"
        ]
        
        guard ensureFiles(files) else {
            XCTAssert(false, "Could create files for testing.")
            return
        }
        
        // tmp is special because it is symlinked to /private/tmp and this /private prefix should be dropped,
        // so tmp is tmp. On Linux tmp is not symlinked so it would be the same.
        do {
            let url = URL(fileURLWithPath: "/.//tmp/ABC/..")
            let result = url.resolvingSymlinksInPath().absoluteString
            XCTAssertEqual(result, "file:///tmp/", "URLByResolvingSymlinksInPath removes extraneous path components and resolve symlinks.")
        }
        
        do {
            let url = URL(fileURLWithPath: "~")
            let result = url.resolvingSymlinksInPath().absoluteString
            let expected = "file://" + FileManager.default.currentDirectoryPath + "/~"
            XCTAssertEqual(result, expected, "URLByResolvingSymlinksInPath resolves relative paths using current working directory.")
        }

        do {
            let url = URL(fileURLWithPath: "anysite.com/search")
            let result = url.resolvingSymlinksInPath().absoluteString
            let expected = "file://" + FileManager.default.currentDirectoryPath + "/anysite.com/search"
            XCTAssertEqual(result, expected)
        }

        // tmp is symlinked on OS X only
        #if os(OSX)
        do {
            let url = URL(fileURLWithPath: "/tmp/..")
            let result = url.resolvingSymlinksInPath().absoluteString
            XCTAssertEqual(result, "file:///private/")
        }
        #else
        do {
            let url = URL(fileURLWithPath: "/tmp/ABC/test_URLByResolvingSymlinksInPath")
            let result = url.resolvingSymlinksInPath().absoluteString
            XCTAssertEqual(result, "file:///tmp/ABC/test_URLByResolvingSymlinksInPath", "URLByResolvingSymlinksInPath appends trailing slash for existing directories only")
        }
        #endif

        do {
            let url = URL(fileURLWithPath: "/tmp/ABC/..")
            let result = url.resolvingSymlinksInPath().absoluteString
            XCTAssertEqual(result, "file:///tmp/")
        }
    }
    
    func test_reachable() {
        #if os(Android)
        var url = URL(fileURLWithPath: "/data")
        #else
        var url = URL(fileURLWithPath: "/usr")
        #endif
        XCTAssertEqual(true, try? url.checkResourceIsReachable())
        
        url = URL(string: "https://www.swift.org")!
        do {
            _ = try url.checkResourceIsReachable()
            XCTFail()
        } catch let error as NSError {
            XCTAssertEqual(NSCocoaErrorDomain, error.domain)
            XCTAssertEqual(CocoaError.Code.fileNoSuchFile.rawValue, error.code)
        } catch {
            XCTFail()
        }
        
        url = URL(fileURLWithPath: "/some_random_path")
        do {
            _ = try url.checkResourceIsReachable()
            XCTFail()
        } catch let error as NSError {
            XCTAssertEqual(NSCocoaErrorDomain, error.domain)
            XCTAssertEqual(CocoaError.Code.fileReadNoSuchFile.rawValue, error.code)
        } catch {
            XCTFail()
        }
        
        #if os(Android)
        var nsURL = NSURL(fileURLWithPath: "/data")
        #else
        var nsURL = NSURL(fileURLWithPath: "/usr")
        #endif
        XCTAssertEqual(true, try? nsURL.checkResourceIsReachable())
        
        nsURL = NSURL(string: "https://www.swift.org")!
        do {
            _ = try nsURL.checkResourceIsReachable()
            XCTFail()
        } catch let error as NSError {
            XCTAssertEqual(NSCocoaErrorDomain, error.domain)
            XCTAssertEqual(CocoaError.Code.fileNoSuchFile.rawValue, error.code)
        } catch {
            XCTFail()
        }
        
        nsURL = NSURL(fileURLWithPath: "/some_random_path")
        do {
            _ = try nsURL.checkResourceIsReachable()
            XCTFail()
        } catch let error as NSError {
            XCTAssertEqual(NSCocoaErrorDomain, error.domain)
            XCTAssertEqual(CocoaError.Code.fileReadNoSuchFile.rawValue, error.code)
        } catch {
            XCTFail()
        }
    }

    func test_copy() {
        let url = NSURL(string: "https://www.swift.org")
        let urlCopy = url!.copy() as! NSURL
        XCTAssertTrue(url!.isEqual(urlCopy))

        let queryItem = NSURLQueryItem(name: "id", value: "23")
        let queryItemCopy = queryItem.copy() as! NSURLQueryItem
        XCTAssertTrue(queryItem.isEqual(queryItemCopy))
    }
    
    func test_itemNSCoding() {
        let queryItemA = NSURLQueryItem(name: "id", value: "23")
        let queryItemB = NSKeyedUnarchiver.unarchiveObject(with: NSKeyedArchiver.archivedData(withRootObject: queryItemA)) as! NSURLQueryItem
        XCTAssertEqual(queryItemA, queryItemB, "Archived then unarchived query item must be equal.")
    }

    func test_dataRepresentation() {
        let url = NSURL(fileURLWithPath: "/tmp/foo")
        let url2 = NSURL(dataRepresentation: url.dataRepresentation,
            relativeTo: nil)
        XCTAssertEqual(url, url2)
    }
}
    
class TestURLComponents : XCTestCase {
    static var allTests: [(String, (TestURLComponents) -> () throws -> Void)] {
        return [
            ("test_queryItems", test_queryItems),
            ("test_string", test_string),
            ("test_port", test_portSetter),
            ("test_url", test_url),
            ("test_copy", test_copy),
            ("test_createURLWithComponents", test_createURLWithComponents)
        ]
    }
    
    func test_queryItems() {
        let urlString = "http://localhost:8080/foo?bar=&bar=baz"
        let url = URL(string: urlString)!

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)

        var query = [String: String]()
        components?.queryItems?.forEach {
            query[$0.name] = $0.value ?? ""
        }
        XCTAssertEqual(["bar": "baz"], query)
    }

    func test_string() {
        for obj in getTestData()! {
            let testDict = obj as! [String: Any]
            let unencodedString = testDict[kURLTestUrlKey] as! String
            let expectedString = NSString(string: unencodedString).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
            guard let components = URLComponents(string: expectedString) else { continue }
            XCTAssertEqual(components.string!, expectedString, "should be the expected string (\(components.string!) != \(expectedString))")
        }
    }
    
    func test_portSetter() {
        let urlString = "http://myhost.mydomain.com"
        let port: Int = 8080
        let expectedString = "http://myhost.mydomain.com:8080"
        var url = URLComponents(string: urlString)
        url!.port = port
        let receivedString = url!.string
        XCTAssertEqual(receivedString, expectedString, "expected \(expectedString) but received \(receivedString as Optional)")
    }

    func test_url() {

        let baseURL = URL(string: "https://www.example.com")

        /* test NSURLComponents without authority */
        var compWithAuthority = URLComponents(string: "https://www.swift.org")
        compWithAuthority!.path = "/path/to/file with space.html"
        compWithAuthority!.query = "id=23&search=Foo Bar"
        var expectedString = "https://www.swift.org/path/to/file%20with%20space.html?id=23&search=Foo%20Bar"
        XCTAssertEqual(compWithAuthority!.string, expectedString, "expected \(expectedString) but received \(compWithAuthority!.string as Optional)")

        var aURL = compWithAuthority!.url(relativeTo: baseURL)
        XCTAssertNotNil(aURL)
        XCTAssertNil(aURL!.baseURL)
        XCTAssertEqual(aURL!.absoluteString, expectedString, "expected \(expectedString) but received \(aURL!.absoluteString)")

        compWithAuthority!.path = "path/to/file with space.html" //must start with /
        XCTAssertNil(compWithAuthority!.string) // must be nil

        aURL = compWithAuthority!.url(relativeTo: baseURL)
        XCTAssertNil(aURL) //must be nil



        /* test NSURLComponents without authority */
        var compWithoutAuthority = URLComponents()
        compWithoutAuthority.path = "path/to/file with space.html"
        compWithoutAuthority.query = "id=23&search=Foo Bar"
        expectedString = "path/to/file%20with%20space.html?id=23&search=Foo%20Bar"
        XCTAssertEqual(compWithoutAuthority.string, expectedString, "expected \(expectedString) but received \(compWithoutAuthority.string as Optional)")

        aURL = compWithoutAuthority.url(relativeTo: baseURL)
        XCTAssertNotNil(aURL)
        expectedString = "https://www.example.com/path/to/file%20with%20space.html?id=23&search=Foo%20Bar"
        XCTAssertEqual(aURL!.absoluteString, expectedString, "expected \(expectedString) but received \(aURL!.absoluteString)")

        compWithoutAuthority.path = "//path/to/file with space.html" //shouldn't start with //
        XCTAssertNil(compWithoutAuthority.string) // must be nil

        aURL = compWithoutAuthority.url(relativeTo: baseURL)
        XCTAssertNil(aURL) //must be nil
    }

    func test_copy() {
        let urlString = "https://www.swift.org/path/to/file.html?id=name"
        let urlComponent = NSURLComponents(string: urlString)!
        let copy = urlComponent.copy() as! NSURLComponents

        /* Assert that NSURLComponents.copy did not return self */
        XCTAssertFalse(copy === urlComponent)

        /* Assert that NSURLComponents.copy is actually a copy of NSURLComponents */ 
        XCTAssertTrue(copy.isEqual(urlComponent))
    }
    
    func test_createURLWithComponents() {
        let urlComponents = NSURLComponents()
        urlComponents.scheme = "https";
        urlComponents.host = "com.test.swift";
        urlComponents.path = "/test/path";
        let date = Date()
        let query1 = URLQueryItem(name: "date", value: date.description)
        let query2 = URLQueryItem(name: "simpleDict", value: "false")
        let query3 = URLQueryItem(name: "checkTest", value: "false")
        let query4 = URLQueryItem(name: "someKey", value: "afsdjhfgsdkf^fhdjgf")
        urlComponents.queryItems = [query1, query2, query3, query4]
        XCTAssertNotNil(urlComponents.url?.query)
        XCTAssertEqual(urlComponents.queryItems?.count, 4)
    }

}
