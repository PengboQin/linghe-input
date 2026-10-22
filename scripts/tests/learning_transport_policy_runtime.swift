import Foundation
import PrivateInputKit
@main enum Check {
 static func main() {
  var checks=0
  func check(_ value:Bool) {precondition(value);checks+=1}
  let now:UInt64=1_800_000_000
  check(!LearningTransportPolicy.cloudIsCurrent(now:now,verifiedAt:nil,scopeMatches:true,enabled:true))
  check(!LearningTransportPolicy.cloudIsCurrent(now:now,verifiedAt:now,scopeMatches:false,enabled:true))
  check(!LearningTransportPolicy.cloudIsCurrent(now:now,verifiedAt:now,scopeMatches:true,enabled:false))
  check(!LearningTransportPolicy.cloudIsCurrent(now:now,verifiedAt:now+1,scopeMatches:true,enabled:true))
  check(!LearningTransportPolicy.cloudIsCurrent(now:now,verifiedAt:now-7*86400,scopeMatches:true,enabled:true))
  check(LearningTransportPolicy.cloudIsCurrent(now:now,verifiedAt:now-7*86400+1,scopeMatches:true,enabled:true))
  check(LearningTransportPolicy.legacyCompatibilityDue(now:now,lastSuccess:nil,cloudCurrent:true))
  check(LearningTransportPolicy.legacyCompatibilityDue(now:now,lastSuccess:now-10,cloudCurrent:false))
  check(LearningTransportPolicy.legacyCompatibilityDue(now:now,lastSuccess:now+1,cloudCurrent:true))
  check(!LearningTransportPolicy.legacyCompatibilityDue(now:now,lastSuccess:now-600,cloudCurrent:true))
  check(!LearningTransportPolicy.legacyCompatibilityDue(now:now,lastSuccess:now-86399,cloudCurrent:true))
  check(LearningTransportPolicy.legacyCompatibilityDue(now:now,lastSuccess:now-86400,cloudCurrent:true))
  // Refreshing a cloud lease every ten minutes never moves the daily repair.
  let compatibility=now-86000
  check(!LearningTransportPolicy.legacyCompatibilityDue(now:now,lastSuccess:compatibility,cloudCurrent:true))
  check(LearningTransportPolicy.legacyCompatibilityDue(now:now+400,lastSuccess:compatibility,cloudCurrent:true))
  print("{\"assertions\":\(checks),\"clockRollbackScopeAndDailyBoundary\":true}")
 }
}
