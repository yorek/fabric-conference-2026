select * from dbo.WikipediaArticles 
where id >= 1000000
order by id desc
go

-- delete from dbo.WikipediaArticles where id >= 1000000
-- go

exec dbo.WikipediaArticlesSearch @text = 'fabric\ssql'

