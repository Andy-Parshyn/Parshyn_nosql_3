// =============================================================================
// Частина 3 — Запити різної складності
// Запуск окремого запиту:
//   cat queries/part3.cypher | docker exec -i neo4j_movielens \
//        cypher-shell -u neo4j -p password123
// (або копіюйте конкретний запит у Neo4j Browser)
// =============================================================================

// -----------------------------------------------------------------------------
// Запит 1 (базовий). Усі фільми жанру "Thriller" із середнім рейтингом > 4.0.
// Спершу звужуємо до Thriller-фільмів (селективний MATCH), потім агрегуємо їхні
// оцінки. avg() не можна класти у WHERE — фільтруємо після WITH.
// -----------------------------------------------------------------------------
MATCH (m:Movie)-[:HAS_GENRE]->(:Genre {name: 'Thriller'})
MATCH (m)<-[r:RATED]-(:User)
WITH m, avg(r.rating) AS avgRating, count(r) AS numRatings
WHERE avgRating > 4.0
RETURN m.title AS title, round(avgRating, 3) AS avgRating, numRatings
ORDER BY avgRating DESC, numRatings DESC;

// -----------------------------------------------------------------------------
// Запит 2 (базовий). Користувачі, які поставили оцінку 5 більш ніж 50 фільмам.
// Inline-властивість {rating: 5} матчить лише пʼятірки, рахуємо по ребру r.
// -----------------------------------------------------------------------------
MATCH (u:User)-[r:RATED {rating: 5.0}]->(:Movie)
WITH u, count(r) AS fiveStarCount
WHERE fiveStarCount > 50
RETURN u.userId AS userId, fiveStarCount
ORDER BY fiveStarCount DESC;

// -----------------------------------------------------------------------------
// Запит 3 (середній). Фільми, які ОБИДВА користувачі (userId=1 і userId=2)
// оцінили високо (>= 4). Один шаблон-шлях змушує обидва ребра вести до одного
// й того самого вузла Movie -> перетин виходить природно.
// -----------------------------------------------------------------------------
MATCH (u1:User {userId: 1})-[r1:RATED]->(m:Movie)<-[r2:RATED]-(u2:User {userId: 2})
WHERE r1.rating >= 4 AND r2.rating >= 4
RETURN m.movieId AS movieId, m.title AS title,
       r1.rating AS user1Rating, r2.rating AS user2Rating
ORDER BY m.title;

// -----------------------------------------------------------------------------
// Запит 4 (середній). Жанри, чиї фільми стабільно отримують високі оцінки:
// середній рейтинг і кількість оцінок. Сортуємо за avg, тоді за обсягом.
// (Поріг numRatings відсікає шум від малих жанрів — напр. Documentary/Film-Noir.)
// -----------------------------------------------------------------------------
MATCH (g:Genre)<-[:HAS_GENRE]-(:Movie)<-[r:RATED]-(:User)
WITH g, avg(r.rating) AS avgRating, count(r) AS numRatings
RETURN g.name AS genre, round(avgRating, 3) AS avgRating, numRatings
ORDER BY avgRating DESC, numRatings DESC;

// -----------------------------------------------------------------------------
// Запит 5 (складний). Рекомендація "користувачі зі схожими смаками також
// дивилися" для userId=1.
//  1) Беремо фільми, які цільовий користувач оцінив високо (>=4) — профіль смаку.
//  2) Знаходимо peer-ів, які теж високо оцінили ці фільми. similarity = к-сть
//     спільних високих оцінок (overlap). Лишаємо лише схожих (overlap>=5) і топ-50
//     peer-ів — це обмежує розрив і не дає декартового вибуху.
//  3) Рекомендуємо фільми, які peer-и оцінили високо, а цільовий ще НЕ оцінював.
//     Скор = сума overlap-ів peer-ів, що радять фільм (фільм, який радять багато
//     схожих користувачів, піднімається вище).
// -----------------------------------------------------------------------------
MATCH (target:User {userId: 1})-[tr:RATED]->(seed:Movie)
WHERE tr.rating >= 4
WITH target, collect(seed) AS likedMovies
UNWIND likedMovies AS seed
MATCH (seed)<-[pr:RATED]-(peer:User)
WHERE pr.rating >= 4 AND peer <> target
WITH target, likedMovies, peer, count(DISTINCT seed) AS overlap
WHERE overlap >= 5
WITH target, likedMovies, peer, overlap
ORDER BY overlap DESC
LIMIT 50
MATCH (peer)-[rr:RATED]->(rec:Movie)
WHERE rr.rating >= 4
  AND NOT rec IN likedMovies
  AND NOT EXISTS { (target)-[:RATED]->(rec) }
WITH rec, sum(overlap) AS score, count(DISTINCT peer) AS supporters
RETURN rec.movieId AS movieId, rec.title AS title, score, supporters
ORDER BY score DESC, supporters DESC
LIMIT 20;

// -----------------------------------------------------------------------------
// Запит 6 (складний). Найкоротший ланцюжок між двома користувачами через спільні
// фільми. shortestPath повертає один мінімальний шлях; *..6 обмежує глибину
// (необмежений shortestPath по щільному графу — дорогий). Граф дводольний
// (User-RATED->Movie<-RATED-User), тож довжини шляху завжди ПАРНІ.
// -----------------------------------------------------------------------------
MATCH p = shortestPath((u1:User {userId: 1})-[:RATED*..6]-(u2:User {userId: 6040}))
RETURN [n IN nodes(p) | coalesce(n.title, 'User ' + toString(n.userId))] AS chain,
       length(p) AS hops;
