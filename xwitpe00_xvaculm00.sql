

/*
    Tento příkaz na dropovani tabulek byl vytvořen s pomocí stackoverflow, nemohli jsme najít efektivní způsob jak to
    udělat a přišlo nám to lepší než dropovat tabulky manuálně
*/
DECLARE
    v_sql VARCHAR2(200);
BEGIN
    FOR cur IN (SELECT table_name FROM user_tables) LOOP
        IF cur.table_name = 'RezervaceDetail' THEN
            v_sql := 'DROP MATERIALIZED VIEW RezervaceDetail';
            EXECUTE IMMEDIATE v_sql;
        ELSE
            v_sql := 'DROP TABLE ' || cur.table_name || ' CASCADE CONSTRAINTS';
            EXECUTE IMMEDIATE v_sql;
        END IF;
    END LOOP;
END;
/

CREATE TABLE RegistrovanyUzivatel
(
    id INT GENERATED AS IDENTITY NOT NULL PRIMARY KEY,
    jmeno VARCHAR2(40) NOT NULL,
    prijmeni VARCHAR2(70) NOT NULL,
    pohlavi VARCHAR2(1),
    rodne_cislo VARCHAR2(10),
    datum_narozeni DATE,
    email VARCHAR2(100) NOT NULL CHECK(REGEXP_LIKE(email, '^\w+@\w+\.\w+$')),
    telefon VARCHAR2(20),
    adresa VARCHAR2(128),

    -- Správce
    -- Vybrána možnost reprezentace generalizace/specializace č.4 - všechno v jedné tabulce
    -- Defaultní stav je NULL, tedy základní uživatel
    -- Při nastavení role je tedy přidána specializace správce
    role VARCHAR2(15) CHECK(role IN('administrator', 'helper'))
);

CREATE TABLE Rezervace
(
    id INT GENERATED AS IDENTITY NOT NULL PRIMARY KEY,
    cena INT NOT NULL,
    stav VARCHAR2(10) CHECK(stav IN('vytvorena', 'zaplacena', 'zrusena')),

    id_tvurce INT NOT NULL,

    CONSTRAINT rezervace_fk FOREIGN KEY (id_tvurce)
        REFERENCES RegistrovanyUzivatel (ID) ON DELETE CASCADE
);

--- Trigger #1 RezervaceZmenaStavu
CREATE TABLE RezervaceZmenaStavu
(
    id INT GENERATED AS IDENTITY NOT NULL PRIMARY KEY,
    rezervace INT NOT NULL,

    predchozi_stav VARCHAR2(10) CHECK(predchozi_stav IN('vytvorena', 'zaplacena', 'zrusena', NULL)),
    novy_stav VARCHAR2(10) CHECK(novy_stav IN('vytvorena', 'zaplacena', 'zrusena')),

    CONSTRAINT rezervace_zmena_fk FOREIGN KEY (rezervace)
        REFERENCES Rezervace (id) ON DELETE CASCADE
);

CREATE OR REPLACE TRIGGER RezervaceZmenaStavuTrigger
    AFTER
        INSERT OR UPDATE
        ON Rezervace
    FOR EACH ROW
    BEGIN
        IF :OLD.stav IS NULL OR :NEW.stav <> :OLD.stav THEN
            INSERT INTO RezervaceZmenaStavu(rezervace, predchozi_stav, novy_stav)
                VALUES (:NEW.id, :OLD.stav, :NEW.stav);
        END IF;
    END;
--- / Trigger #1 RezervaceZmenaStavu

CREATE TABLE Cestujici (
    id INT GENERATED AS IDENTITY NOT NULL PRIMARY KEY,
    jmeno VARCHAR2(40) NOT NULL,
    prijmeni VARCHAR2(70) NOT NULL,
    pohlavi VARCHAR2(1) NOT NULL,
    datum_narozeni DATE NOT NULL,
    email VARCHAR2(100) CHECK(REGEXP_LIKE(email, '^\w+@\w+\.\w+$')),
    cislo_pasu VARCHAR2(40),

    id_rezervace INT,

    CONSTRAINT cestujici_fk FOREIGN KEY (id_rezervace)
        REFERENCES Rezervace (id) ON DELETE CASCADE
);

CREATE TABLE Letadlo (
    id INT GENERATED AS IDENTITY NOT NULL PRIMARY KEY,
    model VARCHAR2(40),
    hodin_naletano INT DEFAULT 0,
    stav VARCHAR2(30),
    kapacita INT NOT NULL
);

CREATE TABLE Sedadlo (
    id INT GENERATED AS IDENTITY NOT NULL PRIMARY KEY,
    sedadlo INT NOT NULL,

    trida VARCHAR2(20) CHECK(trida IN('economy', 'premium-economy', 'business', 'first')),

    id_letadla INT,

    CONSTRAINT sedadlo_fk
        FOREIGN KEY (id_letadla)
        REFERENCES letadlo (id)
        ON DELETE CASCADE
);

CREATE TABLE LeteckaSpolecnost (
    id INT GENERATED AS IDENTITY NOT NULL PRIMARY KEY,
    nazev VARCHAR2(50)
);

CREATE TABLE Letiste (
    kod_letiste VARCHAR2(30) NOT NULL PRIMARY KEY,
    nazev VARCHAR2(150),
    souradnice_x VARCHAR2(50),
    souradnice_y VARCHAR2(50),
    typ_letiste VARCHAR2(30)
);

CREATE TABLE Let (
    id INT GENERATED AS IDENTITY NOT NULL PRIMARY KEY,
    nazev VARCHAR2(32),
    datum_zacatku timestamp NOT NULL,
    doba_trvani INT NOT NULL,

    id_spolecnosti INT NOT NULL,
    kod_letiste_start VARCHAR2(30) NOT NULL,
    kod_letiste_konec VARCHAR2(30) NOT NULL,
    id_letadla INT NOT NULL,

    CONSTRAINT let_fk_spolecnost FOREIGN KEY (id_spolecnosti)
        REFERENCES LeteckaSpolecnost (id),
    CONSTRAINT let_fk_start FOREIGN KEY (kod_letiste_start)
        REFERENCES Letiste (kod_letiste),
    CONSTRAINT let_fk_konec FOREIGN KEY (kod_letiste_konec)
        REFERENCES Letiste (kod_letiste),
    CONSTRAINT letadlo_fk FOREIGN KEY (id_letadla)
        REFERENCES Letadlo (id)
);

CREATE TABLE Letenka (
    id INT GENERATED AS IDENTITY NOT NULL PRIMARY KEY,

    id_cestujiciho INT NOT NULL,
    id_sedadla INT NOT NULL,
    id_letu INT NOT NULL,

    CONSTRAINT letenka_fk
        FOREIGN KEY (id_cestujiciho)
        REFERENCES Cestujici (id),
    CONSTRAINT letenka_fk_sedadlo
        FOREIGN KEY (id_sedadla)
        REFERENCES Sedadlo (id),
    CONSTRAINT letenka_fk_let
        FOREIGN KEY (id_letu)
        REFERENCES Let (id)
);

--- Trigger #2 NewsletterCollector
CREATE TABLE NewsletterReceiver
(
    id INT GENERATED AS IDENTITY NOT NULL PRIMARY KEY,
    enabled NUMBER(1) DEFAULT 1, -- default enabled, can be disabled by the receiver
    email VARCHAR2(100) CHECK(REGEXP_LIKE(email, '^\w+@\w+\.\w+$'))
);

CREATE OR REPLACE TRIGGER CestujiciEmailPridanZmenen
    AFTER
        INSERT OR UPDATE
        ON Cestujici
    FOR EACH ROW
    DECLARE
        "old_email_count" NUMBER;
        "new_email_count" NUMBER;
    BEGIN
        IF :OLD.email IS NOT NULL THEN
            SELECT COUNT(*) INTO "old_email_count" FROM NewsletterReceiver nr WHERE nr.email = :OLD.email;
        ELSE
            "old_email_count" := 0;
        END IF;

        SELECT COUNT(*) INTO "new_email_count" FROM NewsletterReceiver nr WHERE nr.email = :NEW.email;

        -- Nechceme posílat newsletter na jednu adresu dvakrát
        IF "new_email_count" = 0 THEN
            IF "old_email_count" <> 0 THEN
                -- Začneme posílat emaily na nový email uživatele a přestaneme posílat na starý
                -- Jestliže se již uživatel v minulosti odhlásil, budeme jeho volbu respektovat nadále
                UPDATE NewsletterReceiver nr SET nr.email = :NEW.email WHERE nr.email = :OLD.email;
            ELSE
                INSERT INTO NewsletterReceiver(email) VALUES(:NEW.email);
           END IF;
        END IF;
    END;
-- \ Trigger #2

-- INSERT --
INSERT INTO RegistrovanyUzivatel (jmeno, prijmeni, pohlavi, rodne_cislo, datum_narozeni, email, telefon, adresa) VALUES ('Jan', 'Novak', 'M', '1234567890', '05-12-2002', 'honzikuvsvet@gmail.com', '+420448323555', 'Svatopluka cecha, 38, Hustopece 69301');
INSERT INTO RegistrovanyUzivatel (jmeno, prijmeni, pohlavi, rodne_cislo, datum_narozeni, email, telefon, adresa, role) VALUES ('Anezka', 'Polivkova', 'F', '9876543210', '05-11-2002', 'polivkovaa@gmail.com', '+420987292929', 'Svatopluka cecha, 38, Hustopece 69301', 'administrator');
-- RegistrovanyUzivatel
INSERT INTO RegistrovanyUzivatel (jmeno, prijmeni, pohlavi, rodne_cislo, datum_narozeni, email, telefon, adresa) VALUES ('Eva', 'Svobodova', 'F', '1122334455', '03-07-1990', 'evasvobodova@email.cz', '+420603112233', 'Hlavni 10, Praha 11000');
INSERT INTO RegistrovanyUzivatel (jmeno, prijmeni, pohlavi, rodne_cislo, datum_narozeni, email, telefon, adresa) VALUES ('Petr', 'Novotny', 'M', '9988776655', '12-09-1985', 'petrnovotny@seznam.cz', '+420732445566', 'Rostislavova 5, Brno 60200');
INSERT INTO RegistrovanyUzivatel (jmeno, prijmeni, pohlavi, rodne_cislo, datum_narozeni, email, telefon, adresa) VALUES ('Katerina', 'Kovarova', 'F', '1122334455', '15-02-1978', 'katerinakovarova@gmail.com', '+420777112233', 'Namesti Miru 8, Ostrava 70000');
INSERT INTO RegistrovanyUzivatel (jmeno, prijmeni, pohlavi, rodne_cislo, datum_narozeni, email, telefon, adresa) VALUES ('Michal', 'Novy', 'M', '9988776655', '27-11-1995', 'michalnovy@email.cz', '+420606556677', 'Masarykovo nabrezi 15, Praha 11000');
INSERT INTO RegistrovanyUzivatel (jmeno, prijmeni, pohlavi, rodne_cislo, datum_narozeni, email, telefon, adresa) VALUES ('Jana', 'Horakova', 'F', '1122334455', '08-04-1982', 'janahorakova@seznam.cz', '+420608112233', 'Husitska 20, Plzen 30100');
INSERT INTO RegistrovanyUzivatel (jmeno, prijmeni, pohlavi, rodne_cislo, datum_narozeni, email, telefon, adresa) VALUES ('Tomas', 'Kubat', 'M', '9988776655', '21-10-1973', 'tomaskubat@gmail.com', '+420775332211', 'Vodickova 12, Brno 60200');
INSERT INTO RegistrovanyUzivatel (jmeno, prijmeni, pohlavi, rodne_cislo, datum_narozeni, email, telefon, adresa, role) VALUES ('Lucie', 'Sedlackova', 'F', '1122334455', '17-06-1986', 'luciesedlackova@email.cz', '+420602112233', 'Trziste 4, Praha 11000', 'administrator');
INSERT INTO RegistrovanyUzivatel (jmeno, prijmeni, pohlavi, rodne_cislo, datum_narozeni, email, telefon, adresa) VALUES ('Pavel', 'Novacek', 'M', '9988776655', '29-03-1989', 'pavelnovacek@seznam.cz', '+420777445566', 'Konevova 20, Ostrava 70000');
INSERT INTO RegistrovanyUzivatel (jmeno, prijmeni, pohlavi, rodne_cislo, datum_narozeni, email, telefon, adresa, role) VALUES ('Barbora', 'Vesela', 'F', '1122334455', '10-11-1992', 'barboravesela@gmail.com', '+420606778899', 'Na Prikope 30, Plzen 30100', 'helper');

INSERT INTO Rezervace (cena, stav, id_tvurce) VALUES (5000, 'zaplacena', 1);
INSERT INTO Rezervace (cena, stav, id_tvurce) VALUES (7000, 'zaplacena', 2);
INSERT INTO Rezervace (cena, stav, id_tvurce) VALUES (4500, 'vytvorena', 3);
INSERT INTO Rezervace (cena, stav, id_tvurce) VALUES (6000, 'zrusena', 4);
INSERT INTO Rezervace (cena, stav, id_tvurce) VALUES (7000, 'vytvorena', 5);
INSERT INTO Rezervace (cena, stav, id_tvurce) VALUES (5500, 'zaplacena', 6);
INSERT INTO Rezervace (cena, stav, id_tvurce) VALUES (6200, 'zaplacena', 7);
INSERT INTO Rezervace (cena, stav, id_tvurce) VALUES (4800, 'vytvorena', 8);
INSERT INTO Rezervace (cena, stav, id_tvurce) VALUES (5300, 'vytvorena', 9);
INSERT INTO Rezervace (cena, stav, id_tvurce) VALUES (6800, 'zrusena', 4);
INSERT INTO Rezervace (cena, stav, id_tvurce) VALUES (5100, 'vytvorena', 1);
INSERT INTO Rezervace (cena, stav, id_tvurce) VALUES (5900, 'zaplacena', 2);

-- Updaty pro ukazku triggeru #1
UPDATE Rezervace SET stav = 'zaplacena' WHERE rezervace.id = 3;
UPDATE Rezervace SET cena = 5000 WHERE rezervace.id = 3;
UPDATE Rezervace SET stav = 'zrusena' WHERE rezervace.id = 3;

-- Cestujici
INSERT INTO Cestujici (jmeno, prijmeni, pohlavi, datum_narozeni, email, id_rezervace, cislo_pasu) VALUES ('Adam', 'Konecny', 'M', '08-12-1975', 'adameksalamek@seznam.cz', 1, '45678901');
INSERT INTO Cestujici (jmeno, prijmeni, pohlavi, datum_narozeni, email, id_rezervace, cislo_pasu) VALUES ('Ondra', 'Beranek', 'M', '04-12-2012', 'uznejsemnafitu@seznam.cz', 2, '56789012');
INSERT INTO Cestujici (jmeno, prijmeni, pohlavi, datum_narozeni, email, id_rezervace, cislo_pasu) VALUES ('Marie', 'Novakova', 'F', '02-08-1965', 'marienovakova@seznam.cz', 1, '12345678');
INSERT INTO Cestujici (jmeno, prijmeni, pohlavi, datum_narozeni, email, id_rezervace, cislo_pasu) VALUES ('Pavel', 'Kral', 'M', '15-07-1988', 'pavelkral@email.cz', 2, '23456789');
INSERT INTO Cestujici (jmeno, prijmeni, pohlavi, datum_narozeni, email, id_rezervace, cislo_pasu) VALUES ('Eva', 'Svobodova', 'F', '20-04-1979', 'evasvobodova@gmail.com', 2, '34567890');
INSERT INTO Cestujici (jmeno, prijmeni, pohlavi, datum_narozeni, email, id_rezervace, cislo_pasu) VALUES ('Lukas', 'Svoboda', 'M', '12-11-1992', 'lukassvoboda@seznam.cz', 2, '45678901');
INSERT INTO Cestujici (jmeno, prijmeni, pohlavi, datum_narozeni, email, id_rezervace, cislo_pasu) VALUES ('Petra', 'Kovarova', 'F', '28-03-1984', 'petrakovarova@email.cz', 4, '56789012');
INSERT INTO Cestujici (jmeno, prijmeni, pohlavi, datum_narozeni, email, id_rezervace, cislo_pasu) VALUES ('Martin', 'Horak', 'M', '04-10-1996', 'martinhorak@gmail.com', 4, '67890123');
INSERT INTO Cestujici (jmeno, prijmeni, pohlavi, datum_narozeni, email, id_rezervace, cislo_pasu) VALUES ('Lucie', 'Kubatova', 'F', '18-05-1981', 'luciekubatova@seznam.cz', 7, '78901234');
INSERT INTO Cestujici (jmeno, prijmeni, pohlavi, datum_narozeni, email, id_rezervace, cislo_pasu) VALUES ('Jakub', 'Vesely', 'M', '09-09-1973', 'jakubvesely@gmail.com', 8, '89012345');
INSERT INTO Cestujici (jmeno, prijmeni, pohlavi, datum_narozeni, email, id_rezervace, cislo_pasu) VALUES ('Eva', 'Pospisilova', 'F', '23-06-1990', 'evapospisilova@email.cz', 9, '90123456');
INSERT INTO Cestujici (jmeno, prijmeni, pohlavi, datum_narozeni, email, id_rezervace, cislo_pasu) VALUES ('Jan', 'Novak', 'M', '07-12-1977', 'honziknovak@seznam.cz', 10, '01234567');

-- Updaty pro ukazku triggeru #2
UPDATE Cestujici c SET c.email = 'adameksalamek@gmail.com' WHERE c.email = 'adameksalamek@seznam.cz';
UPDATE Cestujici c SET c.email = 'jezismarjanovakova@centrum.cz' WHERE c.email = 'marienovakova@seznam.cz';
UPDATE NewsletterReceiver nr SET nr.enabled = 0 WHERE nr.email = 'jezismarjanovakova@centrum.cz';
UPDATE Cestujici c SET c.email = 'doufamzemiuznebudeteposilatmaily@centrum.cz' WHERE c.email = 'jezismarjanovakova@centrum.cz';

-- Letadlo
INSERT INTO Letadlo (model, hodin_naletano, stav, kapacita) VALUES ('Boeing 737', 5000, 'bezzavadny', 200);
INSERT INTO Letadlo (model, hodin_naletano, stav, kapacita) VALUES ('Boeing 737', 7000, 'opotrebeny', 180);
INSERT INTO Letadlo (model, hodin_naletano, stav, kapacita) VALUES ('Boeing 737', 5500, 'bezzavadny', 250);
INSERT INTO Letadlo (model, hodin_naletano, stav, kapacita) VALUES ('Airbus A380', 8000, 'opotrebeny', 300);
INSERT INTO Letadlo (model, hodin_naletano, stav, kapacita) VALUES ('Boeing 737', 3500, 'bezzavadny', 100);
INSERT INTO Letadlo (model, hodin_naletano, stav, kapacita) VALUES ('Airbus A380', 6000, 'opotrebeny', 80);
INSERT INTO Letadlo (model, hodin_naletano, stav, kapacita) VALUES ('Boeing 777', 7000, 'bezzavadny', 280);
INSERT INTO Letadlo (model, hodin_naletano, stav, kapacita) VALUES ('Airbus A380', 4500, 'opotrebeny', 220);
INSERT INTO Letadlo (model, hodin_naletano, stav, kapacita) VALUES ('Airbus A380', 6000, 'bezzavadny', 260);
INSERT INTO Letadlo (model, hodin_naletano, stav, kapacita) VALUES ('Airbus A380', 5500, 'opotrebeny', 240);
INSERT INTO Letadlo (model, hodin_naletano, stav, kapacita) VALUES ('Embraer E195', 4000, 'bezzavadny', 110);
INSERT INTO Letadlo (model, hodin_naletano, stav, kapacita) VALUES ('Bombardier CRJ700', 5000, 'opotrebeny', 70);


-- Sedadlo
INSERT INTO Sedadlo (sedadlo, trida, id_letadla) VALUES (10, 'economy', 1);
INSERT INTO Sedadlo (sedadlo, trida, id_letadla) VALUES (15, 'business', 2);
INSERT INTO Sedadlo (sedadlo, trida, id_letadla) VALUES (20, 'economy', 1);
INSERT INTO Sedadlo (sedadlo, trida, id_letadla) VALUES (25, 'business', 2);
INSERT INTO Sedadlo (sedadlo, trida, id_letadla) VALUES (30, 'economy', 3);
INSERT INTO Sedadlo (sedadlo, trida, id_letadla) VALUES (35, 'business', 4);
INSERT INTO Sedadlo (sedadlo, trida, id_letadla) VALUES (40, 'economy', 5);
INSERT INTO Sedadlo (sedadlo, trida, id_letadla) VALUES (45, 'business', 6);
INSERT INTO Sedadlo (sedadlo, trida, id_letadla) VALUES (50, 'economy', 7);
INSERT INTO Sedadlo (sedadlo, trida, id_letadla) VALUES (55, 'business', 8);
INSERT INTO Sedadlo (sedadlo, trida, id_letadla) VALUES (60, 'economy', 9);
INSERT INTO Sedadlo (sedadlo, trida, id_letadla) VALUES (65, 'business', 10);


-- LeteckaSpolecnost
INSERT INTO LeteckaSpolecnost (nazev) VALUES ('Lufthansa');
INSERT INTO LeteckaSpolecnost (nazev) VALUES ('United Airlines');
INSERT INTO LeteckaSpolecnost (nazev) VALUES ('British Airways');
INSERT INTO LeteckaSpolecnost (nazev) VALUES ('Delta Air Lines');
INSERT INTO LeteckaSpolecnost (nazev) VALUES ('Emirates');
INSERT INTO LeteckaSpolecnost (nazev) VALUES ('Qatar Airways');
INSERT INTO LeteckaSpolecnost (nazev) VALUES ('Singapore Airlines');
INSERT INTO LeteckaSpolecnost (nazev) VALUES ('Cathay Pacific');
INSERT INTO LeteckaSpolecnost (nazev) VALUES ('Etihad Airways');
INSERT INTO LeteckaSpolecnost (nazev) VALUES ('Qantas');
INSERT INTO LeteckaSpolecnost (nazev) VALUES ('ANA (All Nippon Airways)');
INSERT INTO LeteckaSpolecnost (nazev) VALUES ('Virgin Atlantic');

-- Letiste
INSERT INTO Letiste (kod_letiste, nazev, souradnice_x, souradnice_y, typ_letiste) VALUES ('LAX', 'Los Angeles International Airport', '34.052235', '-118.243683', 'international');
INSERT INTO Letiste (kod_letiste, nazev, souradnice_x, souradnice_y, typ_letiste) VALUES ('JFK', 'John F. Kennedy Domestic Airport', '40.641311', '-73.778139', 'domestic');
INSERT INTO Letiste (kod_letiste, nazev, souradnice_x, souradnice_y, typ_letiste) VALUES ('CDG', 'Paris Charles de Gaulle Airport', '49.0097', '2.5479', 'international');
INSERT INTO Letiste (kod_letiste, nazev, souradnice_x, souradnice_y, typ_letiste) VALUES ('FRA', 'Frankfurt Airport', '50.0333', '8.5706', 'international');
INSERT INTO Letiste (kod_letiste, nazev, souradnice_x, souradnice_y, typ_letiste) VALUES ('DXB', 'Dubai International Airport', '25.2532', '55.3657', 'international');
INSERT INTO Letiste (kod_letiste, nazev, souradnice_x, souradnice_y, typ_letiste) VALUES ('HND', 'Haneda Airport', '35.5533', '139.7811', 'international');
INSERT INTO Letiste (kod_letiste, nazev, souradnice_x, souradnice_y, typ_letiste) VALUES ('LHR', 'London Heathrow Airport', '51.4694', '-0.4513', 'international');
INSERT INTO Letiste (kod_letiste, nazev, souradnice_x, souradnice_y, typ_letiste) VALUES ('AMS', 'Amsterdam Airport Schiphol', '52.3086', '4.7639', 'international');
INSERT INTO Letiste (kod_letiste, nazev, souradnice_x, souradnice_y, typ_letiste) VALUES ('ATL', 'Hartsfield-Jackson Atlanta International Airport', '33.6407', '-84.4277', 'international');
INSERT INTO Letiste (kod_letiste, nazev, souradnice_x, souradnice_y, typ_letiste) VALUES ('ICN', 'Incheon International Airport', '37.4602', '126.4407', 'international');
INSERT INTO Letiste (kod_letiste, nazev, souradnice_x, souradnice_y, typ_letiste) VALUES ('PEK', 'Beijing Capital International Airport', '40.0801', '116.5843', 'international');
INSERT INTO Letiste (kod_letiste, nazev, souradnice_x, souradnice_y, typ_letiste) VALUES ('SIN', 'Singapore Changi Airport', '1.3644', '103.9915', 'international');


-- Let
INSERT INTO Let (nazev, datum_zacatku, doba_trvani, id_spolecnosti, kod_letiste_start, kod_letiste_konec, id_letadla) VALUES ('Flight 123', '04-01-2024 12:04:00', 5, 1, 'LAX', 'JFK', 1);
INSERT INTO Let (nazev, datum_zacatku, doba_trvani, id_spolecnosti, kod_letiste_start, kod_letiste_konec, id_letadla) VALUES ('Flight 456', '04-02-2024 10:00:23', 6, 2, 'JFK', 'LAX', 2);
INSERT INTO Let (nazev, datum_zacatku, doba_trvani, id_spolecnosti, kod_letiste_start, kod_letiste_konec, id_letadla) VALUES ('Flight 789', '04-03-2024 08:30:00', 8, 3, 'CDG', 'DXB', 3);
INSERT INTO Let (nazev, datum_zacatku, doba_trvani, id_spolecnosti, kod_letiste_start, kod_letiste_konec, id_letadla) VALUES ('Flight 1011', '04-04-2024 15:45:00', 10, 3, 'FRA', 'LHR', 4);
INSERT INTO Let (nazev, datum_zacatku, doba_trvani, id_spolecnosti, kod_letiste_start, kod_letiste_konec, id_letadla) VALUES ('Flight 1213', '04-05-2024 11:20:00', 7, 3, 'DXB', 'ICN', 5);
INSERT INTO Let (nazev, datum_zacatku, doba_trvani, id_spolecnosti, kod_letiste_start, kod_letiste_konec, id_letadla) VALUES ('Flight 1415', '04-06-2024 09:10:00', 12, 6, 'HND', 'SIN', 6);
INSERT INTO Let (nazev, datum_zacatku, doba_trvani, id_spolecnosti, kod_letiste_start, kod_letiste_konec, id_letadla) VALUES ('Flight 1617', '04-07-2024 13:55:00', 9, 6, 'LHR', 'AMS', 7);
INSERT INTO Let (nazev, datum_zacatku, doba_trvani, id_spolecnosti, kod_letiste_start, kod_letiste_konec, id_letadla) VALUES ('Flight 1819', '04-08-2024 17:30:00', 11, 7, 'ATL', 'PEK', 8);
INSERT INTO Let (nazev, datum_zacatku, doba_trvani, id_spolecnosti, kod_letiste_start, kod_letiste_konec, id_letadla) VALUES ('Flight 2021', '04-09-2024 14:20:00', 8, 7, 'ICN', 'DXB', 9);
INSERT INTO Let (nazev, datum_zacatku, doba_trvani, id_spolecnosti, kod_letiste_start, kod_letiste_konec, id_letadla) VALUES ('Flight 2223', '04-10-2024 10:00:00', 10, 10, 'PEK', 'AMS', 10);
INSERT INTO Let (nazev, datum_zacatku, doba_trvani, id_spolecnosti, kod_letiste_start, kod_letiste_konec, id_letadla) VALUES ('Flight 2425', '04-11-2024 08:45:00', 7, 1, 'AMS', 'CDG', 1);
INSERT INTO Let (nazev, datum_zacatku, doba_trvani, id_spolecnosti, kod_letiste_start, kod_letiste_konec, id_letadla) VALUES ('Flight 2627', '04-12-2024 12:30:00', 9, 2, 'SIN', 'FRA', 2);


-- Letenka
INSERT INTO Letenka (id_cestujiciho, id_sedadla, id_letu) VALUES (3, 3, 1);
INSERT INTO Letenka (id_cestujiciho, id_sedadla, id_letu) VALUES (3, 3, 1);
INSERT INTO Letenka (id_cestujiciho, id_sedadla, id_letu) VALUES (3, 3, 1);
INSERT INTO Letenka (id_cestujiciho, id_sedadla, id_letu) VALUES (4, 4, 1);
INSERT INTO Letenka (id_cestujiciho, id_sedadla, id_letu) VALUES (4, 4, 1);
INSERT INTO Letenka (id_cestujiciho, id_sedadla, id_letu) VALUES (4, 4, 1);
INSERT INTO Letenka (id_cestujiciho, id_sedadla, id_letu) VALUES (4, 4, 1);
INSERT INTO Letenka (id_cestujiciho, id_sedadla, id_letu) VALUES (4, 4, 1);
INSERT INTO Letenka (id_cestujiciho, id_sedadla, id_letu) VALUES (5, 5, 4);
INSERT INTO Letenka (id_cestujiciho, id_sedadla, id_letu) VALUES (5, 5, 4);
INSERT INTO Letenka (id_cestujiciho, id_sedadla, id_letu) VALUES (5, 5, 4);
INSERT INTO Letenka (id_cestujiciho, id_sedadla, id_letu) VALUES (6, 6, 4);
INSERT INTO Letenka (id_cestujiciho, id_sedadla, id_letu) VALUES (7, 7, 4);
INSERT INTO Letenka (id_cestujiciho, id_sedadla, id_letu) VALUES (7, 7, 4);
INSERT INTO Letenka (id_cestujiciho, id_sedadla, id_letu) VALUES (8, 8, 6);
INSERT INTO Letenka (id_cestujiciho, id_sedadla, id_letu) VALUES (9, 9, 7);
INSERT INTO Letenka (id_cestujiciho, id_sedadla, id_letu) VALUES (10, 10, 7);
INSERT INTO Letenka (id_cestujiciho, id_sedadla, id_letu) VALUES (1, 1, 9);
INSERT INTO Letenka (id_cestujiciho, id_sedadla, id_letu) VALUES (7, 7, 4);
INSERT INTO Letenka (id_cestujiciho, id_sedadla, id_letu) VALUES (7, 7, 4);
INSERT INTO Letenka (id_cestujiciho, id_sedadla, id_letu) VALUES (7, 7, 4);
INSERT INTO Letenka (id_cestujiciho, id_sedadla, id_letu) VALUES (7, 7, 4);

-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- 2x netrivialni triggery: OK
-- 2x netrivialni ulozene procedury + provedeni: OK
    -- 1x kurzor: OK
    -- 1x osetreni vyjimek: OK
    -- promenna s datovym typem odkazujici se na radek ci typ sloupce tabulky (table_name.column_name%TYPE nebo table_name%ROWTYPE): OK
-- 1x index, vcetne EXPLAIN PLAN pred a po: OK
-- 1x vyuziti EXPLAIN PLAN pro vypis planu provedeni dotazu: OK
    -- spojeni dvou tabulek
    -- agregacni funkce
    -- klauzule GROUP BY
    -- navrh zpusobu jak by bylo mozne dotaz dale urychlit (napr zevedeni noveho indexu), zopakovani EXPLAIN PLAN, porovnani vysledků
-- 1x definice pristupovych prav k databazovym objektum pro druheho clena tymu: OK
-- 1x materializovaný pohled patřící druhému členu týmu a ppoužívající tabulky definované prvním členem týmu, včetně SQL dotazů ukazujících, jak materializovaný pohled funguje: OK

-- Trigger #1 - RezervaceZmenaStavuTrigger
-- Definovany nahore pred ukazkovymi inserty
-- SELECT * FROM RezervaceZmenaStavu;

-- Trigger #2 - CestujiciEmailPridanZmenen
-- Definovany nahore pred ukazkovymi inserty
-- SELECT * FROM NewsletterReceiver;

-- Procedura #1
-- Pocita prumernou cenu rezervace
CREATE OR REPLACE PROCEDURE "average_reservation_cost"
AS
    "reservation_count" NUMBER;
    "reservation_cost_sum" NUMBER;
    "avg_reservation_cost" NUMBER;
BEGIN
   SELECT COUNT(*) INTO "reservation_count" FROM Rezervace;
   SELECT SUM(cena) INTO "reservation_cost_sum" FROM Rezervace;

   "avg_reservation_cost" := "reservation_cost_sum" / "reservation_count";

   DBMS_OUTPUT.PUT_LINE('Prumerna cena rezervace je ' || "avg_reservation_cost" || '.');

   EXCEPTION WHEN ZERO_DIVIDE THEN
    BEGIN
        DBMS_OUTPUT.PUT_LINE('Chyba deleni nulou: pocet rezervaci je nula');
    END;
END;

-- Spusteni
BEGIN
    "average_reservation_cost";
END;
-- / Procedura #1

-- Procedura #2
CREATE OR REPLACE PROCEDURE "total_flight_time_by_plane_model"
    ("plane_model" IN Letadlo.model%TYPE)
AS
    "total_fligth_time" NUMBER;
    "curr_plane_id" Letadlo.id%TYPE;
    "curr_plane_model" Letadlo.model%TYPE;
    "curr_flight_plane_id" Let.id_letadla%TYPE;
    "curr_flight_time" Let.doba_trvani%TYPE;

    CURSOR "plane_cursor" IS SELECT l.id, l.model FROM Letadlo l;
    CURSOR "flight_cursor" IS SELECT l.id_letadla, l.doba_trvani FROM Let l WHERE l.datum_zacatku < CURRENT_TIMESTAMP;
BEGIN

   "total_fligth_time" := 0;
   OPEN "plane_cursor";
   LOOP
       FETCH "plane_cursor" INTO "curr_plane_id", "curr_plane_model";
       EXIT WHEN "plane_cursor"%NOTFOUND;

       IF "plane_model" = "curr_plane_model" THEN
           OPEN "flight_cursor";
           LOOP
               FETCH "flight_cursor" INTO "curr_flight_plane_id", "curr_flight_time";
               EXIT WHEN "flight_cursor"%NOTFOUND;

               IF "curr_flight_plane_id" = "curr_plane_id" THEN
                    "total_fligth_time" := "total_fligth_time" + "curr_flight_time";
               END IF;
           END LOOP;
           CLOSE "flight_cursor";
       END IF;
   END LOOP;
   CLOSE "plane_cursor";

   DBMS_OUTPUT.PUT_LINE('Letadlo s typem ' || "plane_model" || ' naletalo celkem ' || "total_fligth_time" || ' minut.');
END;

-- Spusteni
BEGIN
    "total_flight_time_by_plane_model"('Boeing 737');
    "total_flight_time_by_plane_model"('Airbus A380');
END;
-- / Procedura #2

-- EXPLAIN PLAN
-- Kteří uživatelé s českou doménou v emailu cestovali více než jedenkrát a kolikrát cestovali (1 letenka = 1 cesta)
EXPLAIN PLAN FOR
    SELECT
        CONCAT(CONCAT(c.jmeno, ' '), c.prijmeni) as jmeno,
        COUNT(l.id) as pocet_cest
    FROM Cestujici c
    JOIN Letenka l
        ON c.id = l.id_cestujiciho
    WHERE c.email LIKE '%.cz'
    GROUP BY c.id, c.jmeno, c.prijmeni
    HAVING COUNT(l.id) > 1;

SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);

CREATE INDEX letenka_cestujici ON Letenka(id_cestujiciho);

EXPLAIN PLAN FOR
    SELECT
        CONCAT(CONCAT(c.jmeno, ' '), c.prijmeni) as jmeno,
        COUNT(l.id) as pocet_cest
    FROM Cestujici c
    JOIN Letenka l
        ON c.id = l.id_cestujiciho
    WHERE c.email LIKE '%.cz'
    GROUP BY c.id, c.jmeno, c.prijmeni
    HAVING COUNT(l.id) > 1;

SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);

CREATE INDEX cestujici_id_jmeno_prijmeni_email ON Cestujici(id, jmeno, prijmeni, email);

EXPLAIN PLAN FOR
    SELECT
        CONCAT(CONCAT(c.jmeno, ' '), c.prijmeni) as jmeno,
        COUNT(l.id) as pocet_cest
    FROM Cestujici c
    JOIN Letenka l
        ON c.id = l.id_cestujiciho
    WHERE c.email LIKE '%.cz'
    GROUP BY c.id, c.jmeno, c.prijmeni
    HAVING COUNT(l.id) > 1;

SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);

DROP INDEX letenka_cestujici;
DROP INDEX cestujici_id_jmeno_prijmeni_email;
-- / EXPLAIN PLAN

-- Definice přístupových práv pro druhého člena týmu
GRANT ALL ON RegistrovanyUzivatel TO xwitpe00;
GRANT ALL ON Rezervace TO xwitpe00;
GRANT ALL ON RezervaceZmenaStavu TO xwitpe00;
GRANT ALL ON Cestujici TO xwitpe00;
GRANT ALL ON Letadlo TO xwitpe00;
GRANT ALL ON Sedadlo TO xwitpe00;
GRANT ALL ON LeteckaSpolecnost TO xwitpe00;
GRANT ALL ON Letiste TO xwitpe00;
GRANT ALL ON Let TO xwitpe00;
GRANT ALL ON Letenka TO xwitpe00;
GRANT ALL ON NewsletterReceiver TO xwitpe00;
GRANT EXECUTE ON "total_flight_time_by_plane_model" to xwitpe00;
GRANT EXECUTE ON "average_reservation_cost" to xwitpe00;
-- / Definice přístupových práv pro druhého člena týmu

-- Materializovaný pohled
CREATE MATERIALIZED VIEW RezervaceDetail AS (
    SELECT
        r.id AS RezervaceID,
        r.cena AS Cena,
        r.stav AS Stav,
        COUNT(rz.id) AS PocetZmen,
        MAX(rz.predchozi_stav) KEEP (DENSE_RANK LAST ORDER BY rz.id) AS PredchoziStavRezervace
    FROM Rezervace r
    LEFT JOIN RezervaceZmenaStavu rz ON r.id = rz.rezervace
    GROUP BY r.id, r.cena, r.stav
);

SELECT
    RezervaceID,
    Cena,
    CASE
        WHEN Stav = 'vytvorena' THEN 'Nezaplaceno'
        WHEN Stav = 'zaplacena' THEN 'Zaplaceno'
        WHEN Stav = 'zrusena' THEN 'Zrušeno'
    END AS StavRezervace,
    PocetZmen,
    CASE
        WHEN PredchoziStavRezervace = 'vytvorena' THEN 'Nezaplaceno'
        WHEN PredchoziStavRezervace = 'zaplacena' THEN 'Zaplaceno'
        WHEN PredchoziStavRezervace = 'zrusena' THEN 'Zrušeno'
        WHEN PredchoziStavRezervace IS NULL THEN '-'
    END AS PredchoziStavRezervace
FROM RezervaceDetail;
-- / Materializovaný pohled