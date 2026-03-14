/*
    Code used in the screenshot of the VS Live 2025 Redmond HQ Slide deck
*/
use vslive2025_redmond
go

declare @emailValue nvarchar(100) = 'jd@acme.com';
declare @emailKey nvarchar(100) = 'email';

declare @j json = json_object(
    'firstName': 'John',
    'lastName': 'Doe',
    'roles': json_array('reader', 'writer'),
    'contacts': json_object(
        @emailKey: @emailValue,
        'phone': '123 456 789'
    ) 
)

select @j
go

declare @j json = '
[
    {
        "Number": "SO43659",
        "Date": "2025-05-31T15:34:02",
        "AccountNumber": "AW29825",
        "Price": 59.99,
        "Quantity": 1
    },
    {
        "Number": "SO43661",
        "Date": "2025-06-01T08:13:47",
        "AccountNumber": "AW73565",
        "Price": 24.99,
        "Quantity": 3
    }
]'

select * into #t from openjson(@j) with (
    [Number] varchar(10),
    [Date] datetime2,
    [AccountNumber] varchar(10),
    [Price] decimal(9,4),
    [Quantity] int
)
go

select * from #t;
go

select 
    * 
from 
    #t 
for json auto


