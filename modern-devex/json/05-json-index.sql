use vslive2025_redmond;
go

drop table if exists dbo.test_json_index;
create table dbo.test_json_index
(
    id int not null primary key,
    [document] json not null
)
go

/* 
    Generate some random JSON document
*/
insert into dbo.test_json_index
select 
    [value],
    json_object(
            'id': [value],
            'datetime': sysdatetime(),
            'somedata1': newid(),
            'somedata2': newid(),
            'somedata3': newid(),
            'somedata4': newid(),
            'somedata5': newid(),
            'somedata6': newid(),
            'somearray': json_array(newid(), [value], newid(), newid(), [value])            
    ) as document
from 
    generate_series(1, 100000)
go

/* 
    Add some well-known values to showcase index usage
*/
update dbo.test_json_index set document.modify('$.datetime', '2025-01-01') where id = 1
go

insert into dbo.test_json_index values 
(-1, '{"id":"100"}'),
(-2, '{"id":"abc"}') 
go

/*
    Create JSON Index
*/
create json index ixj on dbo.test_json_index(document)
go

update statistics test_json_index with rowcount = 10000000;
go

set statistics io on
go


/* 
    JSON_VALUE or JSON_CONTAINS: what's difference?    
*/

-- This will error out, as json_value returns a *string*!
select * from dbo.test_json_index
where cast(json_value(document, '$.id') as int) = 100;
go

-- This works as conversion is managed internally
select * from dbo.test_json_index
where json_value(document, '$.id' returning int) = 100;
go

-- otherwise better to use json_contains which return *ONLY* the request type (int in this case) 
select * from dbo.test_json_index
where json_contains(document, 100, '$.id') = 1
go

-- Remove offending rows
delete from dbo.test_json_index where id < 0

-- Range filters are also supported by json index
select * from dbo.test_json_index
where cast(json_value(document, '$.id') as int) between 100 and 125;
go

select * from dbo.test_json_index
where json_value(document, '$.somedata1' returning varchar(64)) LIKE '2A94%';
go

-- Wildcard/pattern-based searches using JSON_CONTAINS
-- Last parameter = 1 means use LIKE instead of =
select * from dbo.test_json_index
where json_contains(document, '2A94%', '$.somedata1', 1) = 1;
go

-- Use the index for a seek predicate
select * from dbo.test_json_index
where json_contains(document, 100, '$.somearray[1]') = 1

-- More expensive as we don't know in which array position to look
select * from dbo.test_json_index
where json_contains(document, 100, '$.somearray[*]') = 1

-- This is also expensive as we don't know how big are arrays
-- and each array might have a different size
select * from dbo.test_json_index 
where json_contains(document, 100, '$.somearray[last]') = 1 

-- doesn't use index on CTP 2.1
select top(10) * from dbo.test_json_index
where json_value(document, '$.datetime' returning datetime2) = '2025-01-01';

-- openjson also benefits from index as we can just read the index to extract all the needed value
select 
    j.*
from 
    dbo.test_json_index t
cross apply 
    openjson(document) with 
    (
        id int,
        [datetime] datetime2
    ) j
where
    j.id = 100
go

-- try dropping the index and run the query again....
drop index ixj on dbo.test_json_index
go

select 
    j.*
from 
    dbo.test_json_index t
cross apply 
    openjson(document) with 
    (
        id int,
        [datetime] datetime2
    ) j
where
    j.id = 100
go
