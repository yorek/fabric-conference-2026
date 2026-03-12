alter database current set compatibility_level = 170;
go

/*
	Cleanup if needed
*/
if not exists(select * from sys.symmetric_keys where [name] = '##MS_DatabaseMasterKey##')
begin
	create master key encryption by password = 'VERY_(Str0nG)_Pa$$w0rd!'
end
go
if exists(select * from sys.[external_data_sources] where name = 'sample_data')
begin
	drop external data source [sample_data];
end
go
if exists(select * from sys.[database_scoped_credentials] where name = 'sample_data')
begin
	drop database scoped credential [sample_data];
end
go

/*
	Create table
*/
drop table if exists [dbo].[WikipediaArticles];
create table [dbo].[WikipediaArticles]
(
	[id] [int] identity not null,
	[url] [varchar](1000) not null,
	[title] [varchar](1000) not null,
	[text] [varchar](max) not null
)
go

alter table dbo.WikipediaArticles
add constraint pk__dbo_WikipediaArticles primary key (id)
go


/*
	Create stored procedure for hybrid-search
*/
create or alter procedure dbo.WikipediaArticlesSearch
@text nvarchar(1000)
as
select
	*
from
	dbo.WikipediaArticles
where	
	regexp_like(title, @text, 'i')
-- or
-- 	regexp_like([text], @text, 'i')