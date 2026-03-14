use vslive2025_redmond;
go

/* 
    Extract a scalar value
*/
declare @j json
select top (1) @j = json_data from dbo.users_json where id = 1
select json_value(@j, '$.firstName')	
go

-- specify the returned type
declare @j json
select top (1) @j = json_data from dbo.users_json where id = 1
select json_value(@j, '$.age' returning int)	
go

-- use Path expression to precisely point to elements in an array
declare @j json
select top (1) @j = json_data from dbo.users_json where id = 1
select json_value(@j, '$.phoneNumbers[last].number') 
go

/*
    Extract a JSON object (or an Array)
*/
declare @j json
select top (1) @j = json_data from dbo.users_json where id = 1
select json_query(@j, '$.address') 
go

declare @j json
select top (1) @j = json_data from dbo.users_json where id = 1
select json_query(@j, '$.phoneNumbers') 
go

/*
    Use Path Expressions
*/

-- Null result as path is returning a list of numbers, not just one
declare @j json
select top (1) @j = json_data from dbo.users_json where id = 1
select json_query(@j, '$.phoneNumbers[*].number') 
go

-- List of numbers in JSON *must* be wrapped into an array
declare @j json
select top (1) @j = json_data from dbo.users_json where id = 1
select json_query(@j, '$.phoneNumbers[*].number' with array wrapper) 
go

declare @j json
select top (1) @j = json_data from dbo.users_json where id = 1
select json_query(@j, '$.phoneNumbers[0 to 1].number' with array wrapper) 
go

declare @j json
select top (1) @j = json_data from dbo.users_json where id = 1
select json_query(@j, '$.phoneNumbers[0 to 1]' with array wrapper) 
go

declare @j json
select top (1) @j = json_data from dbo.users_json where id = 1
select json_query(@j, '$.phoneNumbers[0,2]' with array wrapper) 
go

declare @j json
select top (1) @j = json_data from dbo.users_json where id = 1
select json_query(@j, '$.phoneNumbers[last]') 
go

declare @j json
select top (1) @j = json_data from dbo.users_json where id = 1
select json_query(@j, '$.phoneNumbers[0,last]' with array wrapper) 
go

/*
    Extract all the key-value pairs
*/
declare @j json
select top (1) @j = json_data from dbo.users_json where id = 1
select * from openjson(@j)
go

-- Use a path to select the portion on the document you want to focus on
declare @j json
select top (1) @j = json_data from dbo.users_json where id = 1
select * from openjson(@j, '$.address')
go

/*
    Apply schema-on-read to JSON document
*/
declare @j json
select top (1) @j = json_data from dbo.users_json where id = 1
select
    *
from
    openjson(@j) with
    (
        FirstName nvarchar(50) '$.firstName',
        LastName nvarchar(50) '$.lastName',
        Age int '$.age',
        [State] nvarchar(50) '$.address.state'
    ) as t
go

-- Works on arrays too
declare @j json
select top (1) @j = json_data from dbo.users_json where id = 1
select
    *
from
    openjson(@j, '$.phoneNumbers') with
    (
        [type] nvarchar(50),
        [number] nvarchar(50)
    ) as t

/*
    OPENJSON + CROSS APPLY
    Iterate OPENJSON on all provided rows
*/
select
    j.id,
    p.*
from
    dbo.users_json j
cross apply
    openjson(j.json_data, '$.phoneNumbers') with
    (
        [type] nvarchar(50),
        [number] nvarchar(50)
    ) as p
go

-- A row may contain a document with an array of object
-- Each extract object will be returned on its own line
select
    j.id,
    p.*
from
    dbo.users_json j
cross apply
    openjson(j.json_data, '$') with
    (
        [firstName] nvarchar(50),
        [lastName] nvarchar(50)
    ) as p

-- Using multiple cross appy in sequence it is possible to
-- extract data from nested structures
select
    j.id as document_id,
    t.FirstName,    
    t.LastName,
    t.Age,
    t.State,
    pn.PhoneType,
    pn.PhoneNumber
from
    dbo.users_json as j
cross apply
    openjson(j.json_data) with
    (
        FirstName nvarchar(50) '$.firstName',
        LastName nvarchar(50) '$.lastName',
        Age int '$.age',
        [State] nvarchar(50) '$.address.state',    
        PhoneNumbers nvarchar(max) '$.phoneNumbers' as json
    ) as t
outer apply
    openjson(t.PhoneNumbers) with 
    (
        PhoneType nvarchar(50) '$.type',
        PhoneNumber nvarchar(50) '$.number'
    ) as pn
