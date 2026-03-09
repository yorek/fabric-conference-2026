drop table if exists dbo.WikipediaArticles;
go

select 
    [id] = identity(int, 1, 1),
	[url],
	[title],
	[text]
into
    dbo.WikipediaArticles
from
    [dbo].[wikipedia_articles_embeddings]
go

alter table dbo.WikipediaArticles
add constraint pk__dbo_WikipediaArticles primary key (id)
go

select top(10) * from dbo.WikipediaArticles order by id 
go

select top(10) * from dbo.WikipediaArticles order by id desc
go

delete from dbo.WikipediaArticles where id > 25000

