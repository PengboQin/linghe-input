import Foundation

public enum InputNetworkLane:String,Codable,CaseIterable,Sendable {
    case clipboardLive,relay,activityArchive,recentLearning,cloudLearning
}

/// Process-local aggregate counters. Never retain URLs, headers, identities,
/// request/response bodies or individual timestamps. Wire bytes exclude TLS.
public struct InputNetworkUsage:Codable,Sendable {
    public let lane:InputNetworkLane
    public var tasks:Int64=0
    public var transactions:Int64=0
    public var requestHeaderBytes:Int64=0
    public var requestBodyBytes:Int64=0
    public var responseHeaderBytes:Int64=0
    public var responseBodyBytes:Int64=0
    public var reusedNetworkTransactions:Int64=0
    public var nonReusedNetworkTransactions:Int64=0
}

public enum InputNetworkMetrics {
    private final class Counters:@unchecked Sendable {
        let lock=NSLock()
        var rows:[InputNetworkLane:InputNetworkUsage]=[:]
    }
    private static let counters=Counters()
    public static func snapshot()->[InputNetworkUsage] {
        counters.lock.lock();defer{counters.lock.unlock()}
        return InputNetworkLane.allCases.map{counters.rows[$0] ?? InputNetworkUsage(lane:$0)}
    }
    fileprivate static func record(_ metrics:URLSessionTaskMetrics,lane:InputNetworkLane) {
        counters.lock.lock();defer{counters.lock.unlock()}
        var row=counters.rows[lane] ?? InputNetworkUsage(lane:lane)
        row.tasks+=1
        for t in metrics.transactionMetrics {
            row.transactions+=1
            row.requestHeaderBytes+=max(0,t.countOfRequestHeaderBytesSent)
            row.requestBodyBytes+=max(0,t.countOfRequestBodyBytesSent)
            row.responseHeaderBytes+=max(0,t.countOfResponseHeaderBytesReceived)
            row.responseBodyBytes+=max(0,t.countOfResponseBodyBytesReceived)
            if t.resourceFetchType == .networkLoad {
                if t.isReusedConnection {row.reusedNetworkTransactions+=1}
                else {row.nonReusedNetworkTransactions+=1}
            }
        }
        counters.rows[lane]=row
    }
}

private final class InputHTTPDelegate:NSObject,URLSessionTaskDelegate,@unchecked Sendable {
    let lane:InputNetworkLane
    init(lane:InputNetworkLane) {self.lane=lane}
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void) {completionHandler(nil)}
    func urlSession(_ session:URLSession,task:URLSessionTask,didFinishCollecting metrics:URLSessionTaskMetrics) {InputNetworkMetrics.record(metrics,lane:lane)}
}

/// Retain one ephemeral, bounded session per protocol lane. URLSession pools
/// connections by origin; group credentials remain signed per-request bodies.
/// There are no cookies, cached responses, credential storage or trust overrides.
enum PrivateInputHTTPSessions {
    private static func make(_ lane:InputNetworkLane,timeout:TimeInterval)->URLSession {
        let c=URLSessionConfiguration.ephemeral
        c.httpCookieStorage=nil;c.urlCredentialStorage=nil;c.urlCache=nil
        c.httpShouldSetCookies=false;c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        c.httpMaximumConnectionsPerHost=2;c.timeoutIntervalForResource=timeout
        return URLSession(configuration:c,delegate:InputHTTPDelegate(lane:lane),delegateQueue:nil)
    }
    static let clipboard=make(.clipboardLive,timeout:12)
    static let relay=make(.relay,timeout:30)
    static let activity=make(.activityArchive,timeout:30)
    static let recency=make(.recentLearning,timeout:10)
    static let cloudLearning=make(.cloudLearning,timeout:20)
}
