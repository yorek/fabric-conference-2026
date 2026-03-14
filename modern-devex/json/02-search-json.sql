use vslive2025_redmond;
go

-- Find user by phone number, searching in the phoneNumbers array of objects
select * from users_json
where json_contains(json_data, '020 7946 0986', '$.phoneNumbers[*].number') = 1

-- Check if the provided phone number is the first in the array
select * from users_json
where json_contains(json_data, '020 7946 0986', '$.phoneNumbers[0].number') = 1

-- Check if the provided phone number is the first two numbers in the array
select * from users_json
where json_contains(json_data, '020 7946 0986', '$.phoneNumbers[0 to 1].number') = 1

-- Check if the provided phone number is the last in the array
select * from users_json
where json_contains(json_data, '020 7946 0986', '$.phoneNumbers[last].number') = 1

