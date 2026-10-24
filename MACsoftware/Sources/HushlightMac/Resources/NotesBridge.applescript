use framework "Foundation"
use scripting additions
property writeMayHaveOccurred : false

-- Constant source. All user data arrives through stdin JSON; never evaluated as code.
on emitRows(rows)
    set outputData to current application's NSJSONSerialization's dataWithJSONObject:rows options:0 |error|:(missing value)
    current application's NSFileHandle's fileHandleWithStandardOutput()'s writeData:outputData
end emitRows

on run
    set my writeMayHaveOccurred to false
    try
        set inputData to current application's NSFileHandle's fileHandleWithStandardInput()'s readDataToEndOfFile()
        set payload to current application's NSJSONSerialization's JSONObjectWithData:inputData options:0 |error|:(missing value)
        set operationName to (payload's objectForKey:"operation") as text
        set accountID to (payload's objectForKey:"accountID") as text
        set folderID to (payload's objectForKey:"folderID") as text
        set noteID to (payload's objectForKey:"noteID") as text
        set expectedHTML to (payload's objectForKey:"expectedHTML") as text
        set payloadHTML to (payload's objectForKey:"html") as text
        set pageOffset to (payload's objectForKey:"offset") as integer
        set pageLimit to (payload's objectForKey:"limit") as integer
        set rows to my performOperation(operationName, accountID, folderID, noteID, expectedHTML, payloadHTML, pageOffset, pageLimit)
        my emitRows(rows)
    on error unusedMessage number errorNumber
        -- Never output error strings: Notes may include note content in them.
        if my writeMayHaveOccurred then
            my emitRows({{"error", errorNumber as text, "uncertain"}})
        else
            my emitRows({{"error", errorNumber as text, "not_applied"}})
        end if
    end try
end run

on performOperation(operationName, accountID, folderID, noteID, expectedHTML, payloadHTML, pageOffset, pageLimit)
    with timeout of 20 seconds
        tell application id "com.apple.Notes"
            if operationName is "enable" and accountID is "" and folderID is "" then
                set accountRef to default account
                -- An unrelated same-name folder is never silently adopted.
                if (count of (folders of accountRef whose name is "Agent 工作台")) is not 0 then error number -27001
                set my writeMayHaveOccurred to true
                set folderRef to make new folder at accountRef with properties {name:"Agent 工作台"}
                return {{id of accountRef as text, id of folderRef as text}}
            end if
            if accountID is "" or folderID is "" then error number -27002
            set matchingAccounts to accounts whose id is accountID
            if (count of matchingAccounts) is not 1 then error number -27002
            set accountRef to item 1 of matchingAccounts
            set matchingFolders to folders of accountRef whose id is folderID
            if (count of matchingFolders) is not 1 then error number -27002
            set folderRef to item 1 of matchingFolders
            if (shared of folderRef) then error number -27003
            if (id of container of folderRef as text) is not accountID then error number -27002
            if operationName is "enable" or operationName is "verify" then return {{id of accountRef as text, id of folderRef as text}}
            set noteCount to count of notes of folderRef
            if noteCount > 4096 then error number -27004
            if operationName is "list" then
                if pageOffset < 0 or pageLimit < 1 or pageLimit > 100 or pageOffset > noteCount then error number -27002
                set rows to {{"page", noteCount as text}}
                set pageEnd to pageOffset + pageLimit
                if pageEnd > noteCount then set pageEnd to noteCount
                repeat with noteIndex from (pageOffset + 1) to pageEnd
                    set noteRef to note noteIndex of folderRef
                    set noteTitle to name of noteRef as text
                    if (count characters of noteTitle) > 256 then error number -27004
                    set end of rows to {id of noteRef as text, noteTitle}
                end repeat
                return rows
            end if
            if operationName is "create" then
                if noteCount >= 4096 then error number -27004
                set my writeMayHaveOccurred to true
                set newNote to make new note at folderRef with properties {body:payloadHTML}
                return {{id of newNote as text}}
            end if
            set matchingNotes to notes of folderRef whose id is noteID
            if (count of matchingNotes) is not 1 then error number -27002
            set noteRef to item 1 of matchingNotes
            if (id of container of noteRef as text) is not folderID then error number -27002
            if (password protected of noteRef) or (shared of noteRef) then error number -27003
            if operationName is "append" then
                if (count of attachments of noteRef) is not 0 then error number -27003
                if (body of noteRef as text) is not expectedHTML then error number -27005
                set my writeMayHaveOccurred to true
                set body of noteRef to payloadHTML
                return {{id of noteRef as text}}
            end if
            if operationName is not "read" then error number -27002
            set noteTitle to name of noteRef as text
            set noteText to plaintext of noteRef as text
            set noteHTML to body of noteRef as text
            if (count characters of noteTitle) > 256 or (count characters of noteText) > 24000 or (count characters of noteHTML) > 128000 then error number -27004
            return {{id of noteRef as text, noteTitle, noteText, noteHTML, (count of attachments of noteRef) as text}}
        end tell
    end timeout
end performOperation
