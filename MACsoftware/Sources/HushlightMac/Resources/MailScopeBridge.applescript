use framework "Foundation"
use scripting additions

-- Fixed metadata-only operations. Input values arrive as JSON on stdin and are never compiled.
on emitRows(rows)
    set outputData to current application's NSJSONSerialization's dataWithJSONObject:rows options:0 |error|:(missing value)
    current application's NSFileHandle's fileHandleWithStandardOutput()'s writeData:outputData
end emitRows

on run
    try
        set inputData to current application's NSFileHandle's fileHandleWithStandardInput()'s readDataToEndOfFile()
        set payload to current application's NSJSONSerialization's JSONObjectWithData:inputData options:0 |error|:(missing value)
        set operationName to (payload's objectForKey:"operation") as text
        set accountID to (payload's objectForKey:"accountID") as text
        set mailboxPath to (payload's objectForKey:"mailboxPath") as list
        if operationName is "list" then
            my emitRows(my listScopes())
        else if operationName is "verify" then
            my emitRows(my verifyScope(accountID, mailboxPath))
        else if operationName is "search" then
            set queryText to (payload's objectForKey:"query") as text
            set unreadOnly to (payload's objectForKey:"unreadOnly") as boolean
            my emitRows(my searchMessages(accountID, mailboxPath, queryText, unreadOnly))
        else if operationName is "read" then
            set messageID to (payload's objectForKey:"messageID") as text
            my emitRows(my readMessage(accountID, mailboxPath, messageID))
        else if operationName is "incremental" then
            set sinceEpoch to (payload's objectForKey:"sinceEpoch") as real
            set untilEpoch to (payload's objectForKey:"untilEpoch") as real
            set afterID to (payload's objectForKey:"afterID") as text
            my emitRows(my incrementalMessages(accountID, mailboxPath, sinceEpoch, untilEpoch, afterID))
        else
            error number -27102
        end if
    on error unusedMessage number errorNumber
        -- Mail may include private text in errors; report only the numeric code.
        my emitRows({{"error", errorNumber as text}})
    end try
end run

on listScopes()
    with timeout of 20 seconds
        tell application id "com.apple.mail"
            set rows to {}
            repeat with accountRef in accounts
                set accountID to id of accountRef as text
                set accountName to name of accountRef as text
                set accountAddresses to my joinedAddresses(email addresses of accountRef)
                set rows to my collectBoxes(accountRef, accountID, accountName, accountAddresses, {}, rows, 0)
            end repeat
            return rows
        end tell
    end timeout
end listScopes

on joinedAddresses(addresses)
    set joined to ""
    repeat with addressRef in addresses
        if joined is not "" then set joined to joined & (ASCII character 31)
        set joined to joined & (addressRef as text)
    end repeat
    return joined
end joinedAddresses

on collectBoxes(parentRef, accountID, accountName, accountAddresses, parentPath, rows, depth)
    if depth > 7 then error number -27104
    tell application id "com.apple.mail"
        repeat with boxRef in (mailboxes of parentRef)
            set boxName to name of boxRef as text
            set boxPath to parentPath & {boxName}
            set end of rows to {accountID, accountName, accountAddresses} & boxPath
            if (count of rows) > 200 then error number -27104
            set rows to my collectBoxes(boxRef, accountID, accountName, accountAddresses, boxPath, rows, depth + 1)
        end repeat
    end tell
    return rows
end collectBoxes

on verifyScope(accountID, mailboxPath)
    set {accountRef, boxRef} to my resolveScope(accountID, mailboxPath)
    tell application id "com.apple.mail"
        return {{accountID, name of accountRef as text, my joinedAddresses(email addresses of accountRef)} & mailboxPath}
    end tell
end verifyScope

on resolveScope(accountID, mailboxPath)
    if accountID is "" or (count of mailboxPath) is 0 or (count of mailboxPath) > 8 then error number -27102
    with timeout of 20 seconds
        tell application id "com.apple.mail"
            set matchingAccounts to accounts whose id is accountID
            if (count of matchingAccounts) is not 1 then error number -27102
            set accountRef to item 1 of matchingAccounts
            set parentRef to accountRef
            repeat with component in mailboxPath
                set matchingBoxes to mailboxes of parentRef whose name is (component as text)
                if (count of matchingBoxes) is not 1 then error number -27102
                set parentRef to item 1 of matchingBoxes
            end repeat
            return {accountRef, parentRef}
        end tell
    end timeout
end resolveScope

on messageMetadata(messageRef)
    tell application id "com.apple.mail"
        set nativeID to id of messageRef as text
        set subjectText to subject of messageRef as text
        set senderText to sender of messageRef as text
        set receivedDate to date received of messageRef
        set wasRead to read status of messageRef
    end tell
    set receivedNSDate to receivedDate as «class ocid»
    set receivedEpoch to ((current application's NSNumber's numberWithDouble:(receivedNSDate's timeIntervalSince1970()))'s stringValue()) as text
    if wasRead then
        set unreadFlag to "0"
    else
        set unreadFlag to "1"
    end if
    return {nativeID, subjectText, senderText, receivedEpoch, unreadFlag}
end messageMetadata

on searchMessages(accountID, mailboxPath, queryText, unreadOnly)
    set {accountRef, boxRef} to my resolveScope(accountID, mailboxPath)
    with timeout of 20 seconds
        tell application id "com.apple.mail"
            set messageCount to count of messages of boxRef
            if messageCount > 1000 then error number -27105
            set messageRefs to messages of boxRef
        end tell
        set rows to {}
        repeat with messageRef in messageRefs
            set metadataRow to my messageMetadata(messageRef)
            set matchingQuery to false
            ignoring case
                if queryText is "" or (item 2 of metadataRow contains queryText) or (item 3 of metadataRow contains queryText) then set matchingQuery to true
            end ignoring
            if matchingQuery and ((not unreadOnly) or (item 5 of metadataRow is "1")) then
                set end of rows to metadataRow
                if (count of rows) > 50 then error number -27105
            end if
        end repeat
        return rows
    end timeout
end searchMessages

-- Mail performs the date predicate inside the selected mailbox. This never materializes
-- the full mailbox and deliberately leaves the older search operation unchanged.
on incrementalMessages(accountID, mailboxPath, sinceEpoch, untilEpoch, afterIDText)
    if sinceEpoch < 0 or untilEpoch < sinceEpoch then error number -27105
    set {accountRef, boxRef} to my resolveScope(accountID, mailboxPath)
    set sinceDate to (current application's NSDate's dateWithTimeIntervalSince1970:sinceEpoch) as date
    set untilDate to (current application's NSDate's dateWithTimeIntervalSince1970:untilEpoch) as date
    set afterID to afterIDText as integer
    with timeout of 20 seconds
        tell application id "com.apple.mail"
            set matchingIDs to id of (messages of boxRef whose date received is greater than sinceDate and date received is less than or equal to untilDate and id is greater than afterID)
        end tell
        set sortedIDs to (current application's NSArray's arrayWithArray:matchingIDs)'s sortedArrayUsingSelector:"compare:"
        set idCount to (sortedIDs's |count|()) as integer
        if idCount > 10 then
            set rows to {{"page", "1"}}
        else
            set rows to {{"page", "0"}}
        end if
        set pageCount to idCount
        if pageCount > 10 then set pageCount to 10
        repeat with indexValue from 1 to pageCount
            set targetID to (sortedIDs's objectAtIndex:(indexValue - 1)) as integer
            tell application id "com.apple.mail"
                set pageMessages to messages of boxRef whose id is targetID
                if (count of pageMessages) is not 1 then error number -27106
                set messageRef to item 1 of pageMessages
            end tell
            set end of rows to my messageMetadata(messageRef)
        end repeat
        return rows
    end timeout
end incrementalMessages

on readMessage(accountID, mailboxPath, messageID)
    if messageID is "" then error number -27106
    set {accountRef, boxRef} to my resolveScope(accountID, mailboxPath)
    with timeout of 20 seconds
        tell application id "com.apple.mail"
            set matchingMessages to messages of boxRef whose id is (messageID as integer)
            if (count of matchingMessages) is not 1 then error number -27106
            set messageRef to item 1 of matchingMessages
        end tell
        set metadataRow to my messageMetadata(messageRef)
        tell application id "com.apple.mail" to set bodyText to content of messageRef as text
        if (length of bodyText) > 24000 then error number -27105
        return {metadataRow & {bodyText}}
    end timeout
end readMessage
