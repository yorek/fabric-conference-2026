drop table if exists #articles;
create table #articles (
    article_id int primary key,
    title nvarchar(200),
    tags nvarchar(500)
);

insert into #articles values
(1, 'Getting Started with Azure SQL', 'azure, sql, cloud, database'),
(2, 'Vector Search Deep Dive', 'vectors; embeddings; AI; search'),
(3, 'DiskANN Performance', 'diskann|performance|indexing');

select 
    a.article_id,
    a.title,
    trim(t.value) as tag
from 
    #articles a
cross apply 
    regexp_split_to_table(a.tags, '[,;|]') t
where 
    trim(t.value) <> ''
order by 
    a.article_id, tag;