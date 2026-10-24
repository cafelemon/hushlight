use framework "Foundation"
use scripting additions

-- Fixed Mail dictionary operations. User values arrive only as JSON on stdin.
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
        set nativeID to (payload's objectForKey:"nativeID") as text
        if operationName is "create" then
            set senderAddress to (payload's objectForKey:"sender") as text
            set toAddresses to (payload's objectForKey:"to") as list
            set ccAddresses to (payload's objectForKey:"cc") as list
            set bccAddresses to (payload's objectForKey:"bcc") as list
            set subjectText to (payload's objectForKey:"subject") as text
            set bodyText to (payload's objectForKey:"text") as text
            set accountRef to my resolveAccount(accountID, mailboxPath)
            my assertSender(accountRef, senderAddress)
            my emitRows(my createDraft(senderAddress, toAddresses, ccAddresses, bccAddresses, subjectText, bodyText))
        else if operationName is "read" then
            set accountRef to my resolveAccount(accountID, mailboxPath)
            my emitRows(my readDraft(accountRef, nativeID))
        else if operationName is "send" then
            set senderAddress to (payload's objectForKey:"sender") as text
            set toAddresses to (payload's objectForKey:"to") as list
            set ccAddresses to (payload's objectForKey:"cc") as list
            set bccAddresses to (payload's objectForKey:"bcc") as list
            set subjectText to (payload's objectForKey:"subject") as text
            set bodyText to (payload's objectForKey:"text") as text
            set accountRef to my resolveAccount(accountID, mailboxPath)
            my assertSender(accountRef, senderAddress)
            my emitRows(my sendDraft(nativeID, senderAddress, toAddresses, ccAddresses, bccAddresses, subjectText, bodyText))
        else
            error number -27120
        end if
    on error unusedMessage number errorNumber
        -- Never return Mail's error text; it may contain message content.
        my emitRows({{"error", errorNumber as text, "not_applied"}})
    end try
end run

on resolveAccount(accountID, mailboxPath)
    if accountID is "" or (count of mailboxPath) is 0 or (count of mailboxPath) > 8 then error number -27120
    with timeout of 20 seconds
        tell application id "com.apple.mail"
            set matchingAccounts to accounts whose id is accountID
            if (count of matchingAccounts) is not 1 then error number -27121
            set accountRef to item 1 of matchingAccounts
            considering case, diacriticals, hyphens, punctuation and white space
                if (id of accountRef as text) is not accountID then error number -27121
            end considering
            set parentRef to accountRef
            repeat with component in mailboxPath
                set matchingBoxes to mailboxes of parentRef whose name is (component as text)
                if (count of matchingBoxes) is not 1 then error number -27121
                set parentRef to item 1 of matchingBoxes
                considering case, diacriticals, hyphens, punctuation and white space
                    if (name of parentRef as text) is not (component as text) then error number -27121
                end considering
            end repeat
            return accountRef
        end tell
    end timeout
end resolveAccount

on assertSender(accountRef, senderAddress)
    tell application id "com.apple.mail"
        set selectedAddresses to email addresses of accountRef
        set allAccounts to accounts
    end tell
    set selectedCount to 0
    repeat with addressRef in selectedAddresses
        considering case, diacriticals, hyphens, punctuation and white space
            if (addressRef as text) is senderAddress then set selectedCount to selectedCount + 1
        end considering
    end repeat
    if selectedCount is not 1 then error number -27122
    -- An address shared by two accounts cannot bind the outgoing message to the selected account.
    set ownerCount to 0
    tell application id "com.apple.mail"
        repeat with candidate in allAccounts
            repeat with addressRef in (email addresses of candidate)
                considering case, diacriticals, hyphens, punctuation and white space
                    if (addressRef as text) is senderAddress then set ownerCount to ownerCount + 1
                end considering
            end repeat
        end repeat
    end tell
    if ownerCount is not 1 then error number -27122
end assertSender

on joinedAddresses(addresses)
    set joined to ""
    repeat with addressRef in addresses
        if joined is not "" then set joined to joined & (ASCII character 31)
        set joined to joined & (addressRef as text)
    end repeat
    return joined
end joinedAddresses

on recipientAddresses(recipientRefs)
    set values to {}
    tell application id "com.apple.mail"
        repeat with recipientRef in recipientRefs
            set end of values to address of recipientRef as text
        end repeat
    end tell
    return values
end recipientAddresses

on snapshot(draftRef)
    with timeout of 20 seconds
        tell application id "com.apple.mail"
            set nativeID to id of draftRef as text
            set senderAddress to sender of draftRef as text
            set subjectText to subject of draftRef as text
            set bodyText to content of draftRef as text
            set attachmentsCount to count of attachments of content of draftRef
            set toRefs to to recipients of draftRef
            set ccRefs to cc recipients of draftRef
            set bccRefs to bcc recipients of draftRef
        end tell
        set toAddresses to my recipientAddresses(toRefs)
        set ccAddresses to my recipientAddresses(ccRefs)
        set bccAddresses to my recipientAddresses(bccRefs)
        return {nativeID, senderAddress, my joinedAddresses(toAddresses), my joinedAddresses(ccAddresses), my joinedAddresses(bccAddresses), subjectText, bodyText, attachmentsCount as text}
    end timeout
end snapshot

on findDraft(nativeID)
    if nativeID is "" then error number -27120
    try
        set numericID to nativeID as integer
    on error
        error number -27120
    end try
    if numericID < 1 or (numericID as text) is not nativeID then error number -27120
    with timeout of 20 seconds
        tell application id "com.apple.mail"
            set matches to outgoing messages whose id is numericID
            if (count of matches) is not 1 then error number -27121
            return item 1 of matches
        end tell
    end timeout
end findDraft

on readDraft(accountRef, nativeID)
    set draftRef to my findDraft(nativeID)
    set draftRow to my snapshot(draftRef)
    my assertSender(accountRef, item 2 of draftRow)
    return {draftRow}
end readDraft

on createDraft(senderAddress, toAddresses, ccAddresses, bccAddresses, subjectText, bodyText)
    -- Any error after make can leave a draft behind; report unknown, never retry automatically.
    try
        with timeout of 20 seconds
            tell application id "com.apple.mail"
                set draftRef to make new outgoing message with properties {sender:senderAddress, subject:subjectText, content:bodyText, visible:false}
                repeat with addressRef in toAddresses
                    make new to recipient at end of to recipients of draftRef with properties {address:(addressRef as text)}
                end repeat
                repeat with addressRef in ccAddresses
                    make new cc recipient at end of cc recipients of draftRef with properties {address:(addressRef as text)}
                end repeat
                repeat with addressRef in bccAddresses
                    make new bcc recipient at end of bcc recipients of draftRef with properties {address:(addressRef as text)}
                end repeat
                save draftRef
            end tell
        end timeout
        set draftRow to my snapshot(draftRef)
        considering case, diacriticals, hyphens, punctuation and white space
            if (item 2 of draftRow) is not senderAddress or (item 3 of draftRow) is not my joinedAddresses(toAddresses) or (item 4 of draftRow) is not my joinedAddresses(ccAddresses) or (item 5 of draftRow) is not my joinedAddresses(bccAddresses) or (item 6 of draftRow) is not subjectText or (item 7 of draftRow) is not bodyText or (item 8 of draftRow) is not "0" then error number -27124
        end considering
        return {draftRow}
    on error unusedMessage number errorNumber
        return {{"error", errorNumber as text, "unknown"}}
    end try
end createDraft

on sendDraft(nativeID, senderAddress, toAddresses, ccAddresses, bccAddresses, subjectText, bodyText)
    set draftRef to my findDraft(nativeID)
    set draftRow to my snapshot(draftRef)
    considering case, diacriticals, hyphens, punctuation and white space
        if (item 2 of draftRow) is not senderAddress or (item 3 of draftRow) is not my joinedAddresses(toAddresses) or (item 4 of draftRow) is not my joinedAddresses(ccAddresses) or (item 5 of draftRow) is not my joinedAddresses(bccAddresses) or (item 6 of draftRow) is not subjectText or (item 7 of draftRow) is not bodyText or (item 8 of draftRow) is not "0" then return {{"error", "-27122", "not_applied"}}
    end considering
    -- This is Mail accepting a send command, never proof of delivery.
    try
        with timeout of 20 seconds
            tell application id "com.apple.mail" to set accepted to send draftRef
        end timeout
        if accepted is true then return {{"status", "submitted"}}
        return {{"status", "unknown"}}
    on error
        return {{"status", "unknown"}}
    end try
end sendDraft
