use vslive2025_redmond;
go

select * from dbo.users;
select * from dbo.user_addresses;
select * from dbo.user_phones;

/* 
    Using FOR JSON, to create *one* JSON document with the whole resultset
*/

-- Auto: the simplest option
select 
	u.firstName,
	u.lastName,
	u.isAlive,
	u.age,
	[address].streetAddress,
	[address].city,
	[address].[state],
	[address].postalCode
from 
	dbo.users u 
inner join 
	dbo.user_addresses as [address] on u.id = [address].[user_id] 
for 
	json auto
go

-- Path: allow for some shaping
select 
	u.firstName,
	u.lastName,    
	u.isAlive as 'additionalInfo.isAlive',
	u.age as 'additionalInfo.age'
from 
	dbo.users u 
for 
	json path
go

/* 
    With the new functions JSON_OBJECT and JSON_ARRAY
    you have full control over the JSON shape
*/

-- name as an array of name parts
select 
    json_object(
        'id': u.id,
        'name': json_array(firstName, lastName)
    )    
from 
	dbo.users u 
go

-- use id as the key and then create an array of objects
select 
    json_object(
        u.id: json_array(
            json_object('first': firstName, 'last': lastName)
        )
    )    
from 
	dbo.users u 
go

-- phone numbers in an array
select 
    json_object(
        'id': u.id,
        'first_name': firstName,
        'last_name': lastName,
        'phone_numbers': json_arrayagg(up.number)
    )    
from 
	dbo.users u 
left join
    dbo.user_phones up on up.[user_id] = u.id
group by
    u.id, firstName, lastName
go

-- phone numbers in an object array
select 
    json_object(
        'id': u.id,
        'first_name': firstName,
        'last_name': lastName,
        'phone_numbers': json_arrayagg(json_object('type': up.type, 'number': up.number))
    )    
from 
	dbo.users u 
left join
    dbo.user_phones up on up.[user_id] = u.id
group by
    u.id, firstName, lastName
go

-- phone numbers as an object where key is the phone number type
select 
    json_object(
        'id': u.id,
        'first_name': firstName,
        'last_name': lastName,
        'phone_numbers': json_objectagg(up.type: up.number)
    )    
from 
	dbo.users u 
left join
    dbo.user_phones up on up.[user_id] = u.id
group by
    u.id, firstName, lastName
go

