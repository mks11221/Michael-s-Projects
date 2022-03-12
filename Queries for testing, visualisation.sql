------------------------------------ Data prep ----------------------------------------

----------------------------- Pivot table for vaccination types --------------------------
-- Dynamic pivot to show total_vaccinations per vaccine types ordered by date, location and total COVID cases
-- This will be plotted to show if there is any relationship between total cases and the types of vaccines administered
-- The result will be inserted into a new table [dbo.vaccinations-by-manufactuere_pivot]

-- Check if there is an existing table so it can be dropped to be updated
IF OBJECT_ID('dbo.vaccinations-by-manufacturer_pivot') IS NOT NULL
DROP TABLE [dbo.vaccinations-by-manufacturer_pivot]

-- Generate column names to pivot off
DECLARE 
	@columns	NVARCHAR(MAX) = '',
	@sql		NVARCHAR(MAX) = '';

SELECT @columns += QUOTENAME(vaccine) + ',' FROM (
SELECT DISTINCT(vaccine)
FROM [Covid_Project_owd].[dbo].[vaccinations-by-manufacturer]) x
SET @columns = LEFT(@columns, LEN(@columns)-1);

-- Dynamic pivot using the above generated column names
SET @sql = '
SELECT * INTO [Covid_Project_owd].[dbo].[vaccinations-by-manufacturer_pivot]
FROM(
	SELECT
		vbm.location,
		vbm.date,
		vaccine,
		total_vaccinations,
		total_cases
	FROM [Covid_Project_owd].[dbo].[vaccinations-by-manufacturer] vbm
	JOIN [Covid_Project_owd].[dbo].[confirmed_cases] cc
		ON vbm.date = cc.date AND vbm.location = cc.location
) t
PIVOT(
	SUM(total_vaccinations)
	FOR vaccine IN ('+@columns +')
) as vaccine_types
ORDER BY location, date
'
EXECUTE sp_executesql @sql;
GO


----------------------------- Pivot table for hopitalisation types --------------------------
-- Dynamic pivot to show total_vaccinations per vaccine types ordered by date, location and total COVID cases
-- This will be plotted to show if there is any relationship between total cases and the types of vaccines administered
-- A new table [covid-hospitaliztions_pivot] would be created containing the pivoted data to be cleaned

-- Generate column names to pivot off
IF OBJECT_ID('dbo.covid-hospitalizations_pivot') IS NOT NULL
DROP TABLE [Covid_Project_owd].[dbo].[covid-hospitalizations_pivot]

DECLARE 
	@columns	NVARCHAR(MAX) = '',
	@sql		NVARCHAR(MAX) = '';

SELECT @columns += QUOTENAME(indicator) + ',' FROM (
SELECT DISTINCT(indicator)
FROM [Covid_Project_owd].[dbo].[covid-hospitalizations]) x
SET @columns = LEFT(@columns, LEN(@columns)-1);

-- Dynamic pivot using the above generated column names
SET @sql = '
SELECT * into [Covid_Project_owd].[dbo].[covid-hospitalizations_pivot]
FROM [Covid_Project_owd].[dbo].[covid-hospitalizations]
PIVOT(
	SUM(value)
	FOR indicator IN ('+@columns +')
) as hospitalisation_types
ORDER BY iso_code, date
'
EXECUTE sp_executesql @sql;
GO



------------------------------------ 1. Severity of COVID ----------------------------------------
-------- Spread/rate of confirmed COVID cases over the population
SELECT	cc.iso_code,
		cc.date, 
		cc.location, 
		isnull(total_cases, 0) total_cases, 
		isnull(new_cases,0) new_cases,
		ISNULL(new_deaths, 0) new_deaths,
		population,

		---- Speed/rate of infection for COVID
		CAST(CAST(isnull(total_cases, 0) AS DECIMAL(15,4))/population * 100 AS decimal(15,4)) AS total_cases_infected_pct,
		CAST(CAST(isnull(new_cases, 0) AS decimal(15,4))/population * 100 AS decimal(15,4)) AS total_new_cases_pct,
		
		---- Mortality rate of cases (per total cases & per capita)
		CAST(ISNULL(NULLIF(cd.total_deaths_per_million, 0)/total_cases_per_million * 100, 0) AS decimal(15,4)) AS death_rate_per_totalcase_pct,
		CAST(ISNULL(NULLIF(cd.total_deaths, 0)/CAST(population AS DECIMAL(15,4)) * 100 ,0) AS decimal(15,4)) AS death_rate_per_capita_pct
FROM dbo.confirmed_cases cc
JOIN dbo.other oth ON cc.date = oth.date AND cc.iso_code = oth.iso_code
JOIN dbo.confirmed_deaths cd ON cc.date = cd.date AND cc.iso_code = cd.iso_code
WHERE cc.iso_code NOT LIKE 'OWID%'
ORDER BY cc.iso_code, cc.date
GO

SELECT DiSTINCT(iso_code)
FROM confirmed_cases
WHERE iso_code NOT LIKE 'OWID%'

-------- Hospitalisations
-- Separated from above query as there is no hospitalisation data for all the countries or for all the periods 
--    (47 Countries available vs 223 countries for the cases dataset)
WITH hospitalisation (entity, iso_code, date, 
						[Daily ICU occupancy], 
						[Daily hospital occupancy],	
						[daily_hospitalisation_movements], 
						[daily_icu_movements])
AS(
SELECT entity,
	hpiv.iso_code, 
	hpiv.date, 
	[Daily ICU occupancy], 
	[Daily hospital occupancy],
	[Daily hospital occupancy] - LAG([Daily hospital occupancy], 1) OVER (PARTITION BY hpiv.iso_code ORDER BY hpiv.date) AS daily_hospitalisation_movements,
	[Daily ICU occupancy] - LAG([Daily ICU occupancy], 1) OVER (PARTITION BY hpiv.iso_code ORDER BY hpiv.date) AS daily_icu_movements
FROM [covid-hospitalizations_pivot] hpiv
JOIN other oth ON hpiv.iso_code = oth.iso_code AND hpiv.date = oth.date
WHERE [Daily ICU occupancy] IS NOT NULL AND [Daily hospital occupancy] IS NOT NULL
)
SELECT * from hospitalisation
WHERE daily_hospitalisation_movements IS NOT NULL AND daily_icu_movements IS NOT NULL
ORDER BY iso_code, date
GO



------------------------------------ 2. Effectiveness of Vaccines ----------------------------------------

-- How much does it reduces the severity of COVID (monthly)
SELECT	cd.iso_code,
		FORMAT(cd.date, 'yyyy-MM') AS date,
		cd.continent,
		cd.location,

		---- To compare the death rates 
		SUM(SUM(new_deaths)) OVER (PARTITION BY cd.location ORDER BY FORMAT(cd.date, 'yyyy-MM')) AS rolling_total_monthly_deaths,
		SUM(new_deaths) AS monthly_new_deaths,
		
		---- Vaccination stats
		SUM(ISNULL(CAST(daily_vaccinations AS INT), 0)) AS monthly_vaccinations,
		ISNULL(SUM(SUM(CAST(daily_vaccinations AS BIGINT))) OVER (PARTITION BY cd.location ORDER BY FORMAT(cd.date, 'yyyy-MM')), 0) AS monthly_rolling_total_vaccinations,
		ISNULL(MAX(MAX(people_vaccinated)) OVER (PARTITION BY cd.location ORDER BY FORMAT(cd.date, 'yyyy-MM')), 0) AS vaccinated,
		ISNULL(MAX(MAX(people_fully_vaccinated)) OVER (PARTITION BY cd.location ORDER BY FORMAT(cd.date, 'yyyy-MM')), 0) AS fully_vaccinated,
		ISNULL(MAX(MAX(total_boosters)) OVER (PARTITION BY cd.location ORDER BY FORMAT(cd.date, 'yyyy-MM')), 0) AS vaccinated_boosters,
		ISNULL(MAX(MAX(people_vaccinated)) OVER (PARTITION BY cd.location ORDER BY FORMAT(cd.date, 'yyyy-MM')) 
			- MAX(MAX(people_fully_vaccinated)) OVER (PARTITION BY cd.location ORDER BY FORMAT(cd.date, 'yyyy-MM')), 0) AS partially_vaccinated,
		
		-- % of fully vaccinated per country per month
		CASE
			-- CASE statement to catch 'divide by zero' error
			WHEN MAX(MAX(people_fully_vaccinated)) OVER (PARTITION BY cd.location ORDER BY FORMAT(cd.date, 'yyyy-MM')) IS NULL OR 
				MAX(MAX(people_fully_vaccinated)) OVER (PARTITION BY cd.location ORDER BY FORMAT(cd.date, 'yyyy-MM')) = 0 THEN 0
			-- Percentage of people fully vacinated 
			ELSE CAST(MAX(MAX(people_fully_vaccinated)) OVER (PARTITION BY cd.location ORDER BY FORMAT(cd.date, 'yyyy-MM'))/CAST(population AS DECIMAL(20,4))* 100 AS DECIMAL(6,3)) 
		END AS pop_fully_vaccinated_pct,
		
		-- % of partially vaccinated per country per month
		CASE
			-- CASE statement to catch 'divide by zero' error
			WHEN ISNULL(MAX(MAX(people_vaccinated)) OVER (PARTITION BY cd.location ORDER BY FORMAT(cd.date, 'yyyy-MM')) 
			- MAX(MAX(people_fully_vaccinated)) OVER (PARTITION BY cd.location ORDER BY FORMAT(cd.date, 'yyyy-MM')), 0) = 0 THEN 0
			-- Percentage of population partly vaccinated
			ELSE CAST((MAX(MAX(people_vaccinated)) OVER (PARTITION BY cd.location ORDER BY FORMAT(cd.date, 'yyyy-MM')) 
			- MAX(MAX(people_fully_vaccinated)) OVER (PARTITION BY cd.location ORDER BY FORMAT(cd.date, 'yyyy-MM'))) /CAST(population AS DECIMAL(20,4))* 100 AS DECIMAL(6,3))
		END AS pop_partly_vaccinated_pct
FROM confirmed_deaths cd
LEFT JOIN vaccinations vac ON cd.date = vac.date AND cd.iso_code = vac.iso_code
JOIN other oth ON cd.iso_code = oth.iso_code AND cd.date = oth.date
WHERE cd.iso_code NOT LIKE 'OWID%'	-- dataset contains aggregates (e.g. continents) that start with OWID-- in the iso_code
GROUP BY FORMAT(cd.date, 'yyyy-MM'), cd.iso_code, cd.location, cd.continent, oth.population
ORDER BY cd.iso_code, FORMAT(cd.date, 'yyyy-MM')
GO



---- Hospitalisation component 
-- separated from the main query as there are only data for some countries as explained in 1. Severity of COVID

-- Used CTE to find the daily hospitalisation movements which is then used to aggregate it by month
WITH hospitalisation_short (entity, iso_code, date, daily_hospitalisation_movements, daily_icu_movements) 
AS 
(
SELECT	entity,
		iso_code, 
		date, 
		[Daily hospital occupancy] - LAG([Daily hospital occupancy], 1) OVER (PARTITION BY hpiv.iso_code ORDER BY hpiv.date) AS daily_hospitalisation_movements,
		[Daily ICU occupancy] - LAG([Daily ICU occupancy], 1) OVER (PARTITION BY hpiv.iso_code ORDER BY hpiv.date) AS daily_icu_movements
FROM [covid-hospitalizations_pivot] hpiv
WHERE [Daily ICU occupancy] IS NOT NULL AND [Daily hospital occupancy] IS NOT NULL
)
SELECT	entity,
		iso_code,

		-- Used DATEADD as using FORMAT straight away had issues with the hospitalisation data
		FORMAT(DATEADD(MONTH, DATEDIFF(MONTH, 0, date), 0), 'Y') AS date_months,
		ISNULL(SUM(SUM(daily_hospitalisation_movements)) OVER (PARTITION BY entity ORDER BY DATEADD(MONTH, DATEDIFF(MONTH, 0, date), 0)),0) AS monthly_hospital_movements,
		ISNULL(SUM(SUM(daily_icu_movements)) OVER (PARTITION BY entity ORDER BY DATEADD(MONTH, DATEDIFF(MONTH, 0, date), 0)),0) AS monthly_ICU_movements
FROM hospitalisation_short
GROUP BY iso_code, DATEADD(MONTH, DATEDIFF(MONTH, 0, date), 0), entity
GO



---- Vaccine type component
-- Dataset contains the different vaccine types that the different countries used
-- (40 countries with 8 vaccine types)

-- Creating a CTE to contain calculations before being grouped up to show monthly figures
WITH infection (date, location, new_cases, infection_rate)
AS(
SELECT	vmp.date,
		vmp.location,
		total_cases - LAG(total_cases, 1) OVER (PARTITION BY vmp.location ORDER BY vmp.date) AS new_cases,
		
		-- Finding the infection rate by using the movement of new cases per week divided by the population of the country
		CASE 
			-- CASE statement to catch the 'divide by zero' error
			WHEN total_cases - LAG(total_cases, 1) OVER (PARTITION BY vmp.location ORDER BY vmp.date) IS NULL OR
				total_cases - LAG(total_cases, 1) OVER (PARTITION BY vmp.location ORDER BY vmp.date) = 0 THEN 0
			-- Movement of weekly cases and divided by the population
			ELSE (total_cases - LAG(total_cases, 1) OVER (PARTITION BY vmp.location ORDER BY vmp.date))/CAST(population AS DECIMAL (15,3)) * 100
		END AS infection_rate
FROM [vaccinations-by-manufacturer_pivot] vmp
JOIN other ON vmp.location = other.location AND vmp.date = other.date
)
SELECT	vmp.location,
		FORMAT(vmp.date, 'Y') AS date,
		
		-- Getting the SUM to group the total amounts by month
		SUM(total_cases) AS monthly_total_cases,
		SUM([Sputnik V]) AS [Sputnik V],
		SUM([Oxford/AstraZeneca]) AS [Oxford/AstraZeneca],
		SUM([CanSino]) AS [CanSino],
		SUM([Johnson&Johnson]) AS [Johnson&Johnson],
		SUM([Moderna]) AS Moderna,
		SUM([Sinopharm/Beijing]) AS [Sinopharm/Beijing],
		SUM(Sinovac) AS Sinovac,
		SUM([Pfizer/BioNTech]) AS [Pfizer/BioNTech],
		SUM(ISNULL(new_cases, 0)) AS monthly_new_cases,

		-- Using the average infection rate for the month
		AVG(infection_rate) AS avg_monthly_infection_rate
FROM [vaccinations-by-manufacturer_pivot] vmp
JOIN infection as inf ON vmp.date = inf.date AND vmp.location = inf.location
GROUP BY FORMAT(vmp.date, 'Y'), vmp.location
ORDER BY vmp.location, FORMAT(vmp.date, 'Y')




------------------------------------ 3. Other factors affecting COVID ----------------------------------------
---- a. Rate of infection
--		Looks at:
--			i.		Population density
--			ii.		Handwashing facility
--			iii.	Stringency index - multiple factors considered (any lockdowns, requirement of masks, no gathering of more than x and etc.
SELECT	other.iso_code,
		other.date,
		other.continent,
		other.location,
		population_density,
		handwashing_facilities,
		stringency_index,
		total_cases_per_million,
		new_cases_per_million
FROM other
JOIN confirmed_cases cc ON other.iso_code = cc.iso_code AND other.date = cc.date
GO


---- b. Take up of vaccines
--		Looks at:
--		i.	GDP per capita
--		ii.	Extreme poverty
--		iii.Increases in deathrate/infection rate

SELECT	oth.location,
		oth.iso_code,
		oth.continent,
		oth.date,
		gdp_per_capita,
		extreme_poverty,
		population,
		CASE
			WHEN total_cases IS NULL or total_cases = 0 THEN 0
			ELSE total_cases/CAST(population AS decimal(15,3)) * 100 
		END AS total_pop_infected,
		CASE
			WHEN total_deaths IS NULL or total_deaths = 0 THEN 0
			ELSE total_deaths/CAST(population AS decimal(15, 3)) * 100
		END AS total_pop_death,
		vac.daily_vaccinations,
		vac.people_fully_vaccinated,
		CASE
			WHEN vac.people_fully_vaccinated IS NULL OR vac.people_fully_vaccinated = 0 THEN 0
			ELSE vac.people_fully_vaccinated/CAST(population AS decimal(15, 3)) * 100
		END AS people_fully_vaccinated_pct
FROM other oth
JOIN confirmed_cases cc ON oth.location = cc.location AND oth.date = cc.date
JOIN confirmed_deaths cd ON oth.location = cd.location AND oth.date = cd.date
JOIN vaccinations vac ON oth.location = vac.location AND oth.date = vac.date
WHERE oth.iso_code NOT LIKE 'OWID%'
ORDER BY oth.iso_code, oth.date
GO


---- c. Contribution to death rate
--		Looks at:
--		i.	% of population aged 65 or older
--		ii.	Extreme poverty/availability of hospital beds
--		iii.Diabetes
--		iv. Smokers

SELECT	cd.iso_code,
		cd.continent,
		cd.location,
		cd.date,
		cd.new_deaths,
		cd.total_deaths,
		population,
		aged_65_older,
		extreme_poverty,
		hospital_beds_per_thousand,
		diabetes_prevalence,
		female_smokers,
		male_smokers,
		female_smokers + male_smokers AS total_smokers
FROM confirmed_deaths cd
JOIN other oth ON cd.iso_code = oth.iso_code AND cd.date = oth.date


------ Other factors affecting COVID in a single query ------
SELECT	oth.iso_code,
		oth.date,
		oth.continent,
		oth.location,
		
		-- Factors that could affect the rate of infection
		population_density,
		handwashing_facilities,
		stringency_index,	-- multiple factors considered (any lockdowns, requirement of masks, no gathering of more than x and etc.
		total_cases_per_million,
		new_cases_per_million,

		-- Factors that could affect the takeup of vaccines
		gdp_per_capita,
		extreme_poverty,
		CASE	-- Getting the % of total population infected as assumption is more would get the vaccine if there were more chance/people infected
			WHEN total_cases IS NULL or total_cases = 0 THEN 0
			ELSE total_cases/CAST(population AS decimal(15,3)) * 100 
		END AS total_pop_infected,
		CASE	-- Getting the % of total pop death - assumption is increased death rate would cause more people to vaccinate
			WHEN total_deaths IS NULL or total_deaths = 0 THEN 0
			ELSE total_deaths/CAST(population AS decimal(15, 3)) * 100
		END AS total_pop_death,
		-- Vaccination data to look at the relationship to the above factors
		vac.daily_vaccinations,
		vac.people_fully_vaccinated,
		CASE	-- Getting the % of fully vaccinated population over time
			WHEN vac.people_fully_vaccinated IS NULL OR vac.people_fully_vaccinated = 0 THEN 0
			ELSE vac.people_fully_vaccinated/CAST(population AS decimal(15, 3)) * 100
		END AS people_fully_vaccinated_pct,

		-- Contribution to death rate
		aged_65_older,
		extreme_poverty,
		hospital_beds_per_thousand,
		diabetes_prevalence,
		female_smokers,
		male_smokers,
		female_smokers + male_smokers AS total_smokers,
		-- death count to look at the relationship to the above factors
		cd.new_deaths,
		cd.total_deaths

FROM other oth
JOIN confirmed_cases cc ON oth.iso_code = cc.iso_code AND oth.date = cc.date
JOIN confirmed_deaths cd ON oth.location = cd.location AND oth.date = cd.date
JOIN vaccinations vac ON oth.location = vac.location AND oth.date = vac.date
WHERE oth.iso_code NOT LIKE 'OWID%'
ORDER BY oth.iso_code, oth.date
GO