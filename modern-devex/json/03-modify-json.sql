use vslive2025_redmond;
go

/*
	With JSON_MODIFY any part of an existing JSON document can be changed
*/
declare @json json = 
N'{
  "firstName": "John",
  "lastName": "Smith",
  "children": []
}';

select * from
( values  
	('Update existing value',           json_modify(@json, '$.firstName', 'Dave')),
	('Insert scalar value',             json_modify(@json, '$.isAlive', 'true')),
	('Insert array',                    json_modify(@json, '$.preferredColors', cast('["Blue", "Black"]' as json))), 
	('Append to array',                 json_modify(@json, 'append $.children', 'Annette')), 
	('Replace an array with a scalar',  json_modify(@json, '$.children', 'Annette')), 
	('Add an object',                   json_modify(@json, '$.phoneNumbers', cast('{"type": "home","number": "212 555-1234"}' as json))), 
	('Remove an object',                json_modify(@json, '$.firstName', null))	
) t([action], result)
go

/*
	In-Place JSON modification
*/

-- Add a new sample user
insert into dbo.users_json
select 42, json_data = '{"firstName": "Joe", "lastName": "Black"}';

-- Update last name
update 
	dbo.users_json
set
	json_data = json_modify(json_data, '$.lastName', 'Green') -- OLD WAY	
output
	inserted.*
where 
    id = 42;

-- Best practice is to use the new .modify method as it does in-place update
-- (Only works on JSON columns)
update 
	dbo.users_json
set	
	json_data.modify('$.lastName', 'Yellow')
output
	inserted.*
where 
    id = 42;

-- Add Phone Number (generates an error in CTP 2.1. Will be fixed in RC0)
update 
	dbo.users_json
set
	json_data.modify(	            		
			'append $.phoneNumbers',
			cast('{"type": "fax","number": "212 555-1234"}' as json)
			)
where 
	id = 42

-- View result
select * from dbo.users_json where id = 42

-- Cleanup
delete from dbo.users_json where id = 42



