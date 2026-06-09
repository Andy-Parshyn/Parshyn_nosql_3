// =============================================================================
// Частина 2 — Завантаження даних
// Запуск (з кореня проєкту):
//   cat queries/part2_load.cypher | docker exec -i neo4j_movielens \
//        cypher-shell -u neo4j -p password123
// =============================================================================

// -----------------------------------------------------------------------------
// Індекси/обмеження ДО завантаження ребер.
// Constraint IS UNIQUE автоматично створює backing-індекс. Це критично: під час
// завантаження ~1M ребер кожен рядок робить MATCH по userId/movieId — без індексу
// це був би повний скан на кожен рядок (години замість хвилин).
// -----------------------------------------------------------------------------
CREATE CONSTRAINT user_id  IF NOT EXISTS FOR (u:User)  REQUIRE u.userId  IS UNIQUE;
CREATE CONSTRAINT movie_id IF NOT EXISTS FOR (m:Movie) REQUIRE m.movieId IS UNIQUE;
CREATE CONSTRAINT genre_nm IF NOT EXISTS FOR (g:Genre) REQUIRE g.name    IS UNIQUE;

// -----------------------------------------------------------------------------
// 1. Користувачі. MERGE (а не CREATE) — захист від дублів при повторному запуску.
//    CSV-значення приходять рядками, тому числові поля приводимо через toInteger.
// -----------------------------------------------------------------------------
LOAD CSV WITH HEADERS FROM 'file:///users.csv' AS row
MERGE (u:User {userId: toInteger(row.userId)})
SET u.gender     = row.gender,
    u.age        = toInteger(row.age),
    u.occupation = toInteger(row.occupation);

// -----------------------------------------------------------------------------
// 2. Фільми + рік (витягуємо з назви "Title (YYYY)") + вузли Genre і HAS_GENRE.
//    Жанри зберігаємо ОКРЕМИМИ вузлами (а не списком у властивості Movie):
//    це дозволяє запити "фільми спільного жанру" і агрегації по жанрах без
//    сканування масивів. split(row.genres,'|') розбиває "Action|Comedy|..." .
// -----------------------------------------------------------------------------
LOAD CSV WITH HEADERS FROM 'file:///movies.csv' AS row
MERGE (m:Movie {movieId: toInteger(row.movieId)})
SET m.title = row.title,
    m.year  = toInteger(substring(row.title, size(row.title) - 5, 4))
WITH m, row
UNWIND split(row.genres, '|') AS gname
MERGE (g:Genre {name: gname})
MERGE (m)-[:HAS_GENRE]->(g);

// -----------------------------------------------------------------------------
// 3. Ребра RATED (~1 000 209). Однією транзакцією завантажити не можна — впаде
//    через памʼять/таймаут. apoc.periodic.iterate розбиває роботу на батчі по
//    10 000. parallel:false — бо кілька потоків конкурували б за блокування одних
//    і тих самих вузлів User/Movie (MERGE ребра). rating -> toFloat, timestamp ->
//    toInteger (значення з CSV — рядки).
// -----------------------------------------------------------------------------
CALL apoc.periodic.iterate(
  "LOAD CSV WITH HEADERS FROM 'file:///ratings.csv' AS row RETURN row",
  "MATCH (u:User  {userId:  toInteger(row.userId)})
   MATCH (m:Movie {movieId: toInteger(row.movieId)})
   MERGE (u)-[r:RATED]->(m)
   SET r.rating    = toFloat(row.rating),
       r.timestamp = toInteger(row.timestamp)",
  {batchSize: 10000, parallel: false}
)
YIELD batches, total, errorMessages
RETURN batches, total, errorMessages;

// -----------------------------------------------------------------------------
// 4. Перевірка результату (очікувано: users=6040, movies=3883, ratings=1000209,
//    genres=18).
// -----------------------------------------------------------------------------
MATCH (u:User)            RETURN count(u) AS users;
MATCH (m:Movie)           RETURN count(m) AS movies;
MATCH ()-[r:RATED]->()    RETURN count(r) AS ratings;
MATCH (g:Genre)           RETURN count(g) AS genres;
