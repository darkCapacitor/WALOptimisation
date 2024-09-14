-- Define the CTE for the calendar data
WITH CalendarCTE AS (
    SELECT AsAtDate, [Month], [Year], RegionCode, IsWorkingDay
    FROM [dbo].[syn_Model_tbl_Dim_Calendar]
    WHERE RegionCode = 'UK' AND IsWorkingDay = 1
), 

RecursiveRepayments AS 
(
    -- Anchor query: Start with initial values
    SELECT
        @FacilityId AS FacilityId,
        @BalanceAmt AS BalanceAmt,
        @RepaymentInterest AS RepaymentInterest,
        @IsFirstPayment AS IsFirstPayment,
        @Sequence AS Sequence,
        @NextPaymentDate AS NextPaymentDate,
        @InterestAppliedToCode AS InterestAppliedToCode,
        @EffIntRate AS EffIntRate,
        @RepayPeriodMths AS RepayPeriodMths,
        @CurrentSequence AS CurrentSequence,
        @ExpiryDate AS ExpiryDate,
        @RepaymentAmt AS RepaymentAmt,
        0 AS InterestAmt,
        @NextInterestSequence AS NextInterestSequence,
        CASE 
            WHEN @IsFirstPayment = 1 THEN @NextPaymentDate
            ELSE DATEADD(MONTH, @RepayPeriodMths, @NextPaymentDate) 
        END AS NextPayment
     
    UNION ALL
    
    -- Recursive query: Calculate for each iteration until balance is non-negative
    SELECT
        r.FacilityId,
        CASE 
            WHEN r.ExpiryDate > r.NextPayment THEN r.BalanceAmt + r.RepaymentAmt
            ELSE r.BalanceAmt
        END AS BalanceAmt,
        CASE 
            WHEN r.ExpiryDate > r.NextPayment THEN r.RepaymentInterest
            ELSE 0.0
        END AS RepaymentInterest,
        0 AS IsFirstPayment, 
        r.Sequence + r.RepayPeriodMths AS Sequence,
        c.AsAtDate AS NextPaymentDate,
        r.InterestAppliedToCode,
        r.EffIntRate,
        r.RepayPeriodMths,
        r.CurrentSequence + 1 AS CurrentSequence,
        r.ExpiryDate,
        r.RepaymentAmt,
        CASE 
            -- Interest calculation based on sequence
            WHEN r.InterestAppliedToCode = '1' AND r.NextInterestSequence = r.CurrentSequence THEN 
                r.BalanceAmt * r.EffIntRate * 90 / 36500
            ELSE 0
        END AS InterestAmt,
        r.NextInterestSequence + CASE WHEN r.InterestAppliedToCode = '1' AND r.NextInterestSequence = r.CurrentSequence THEN 3 ELSE 0 END,
        DATEADD(MONTH, r.RepayPeriodMths, r.NextPayment) AS NextPayment
    FROM RecursiveRepayments r
    INNER JOIN CalendarCTE c
        ON c.[Month] = MONTH(r.NextPayment)
        AND c.[Year] = YEAR(r.NextPayment)
        AND c.AsAtDate <= r.ExpiryDate
    WHERE r.BalanceAmt < 0
)

-- Insert repayment schedules into the temp table
INSERT INTO DW.CAU_RepaymentsSchedules_TEMP (FacilityId, RepaymentAmt, BalanceAmt, NextPaymentDate)
SELECT 
    FacilityId, 
    ABS(BalanceAmt) + RepaymentInterest, 
    CASE 
        WHEN BalanceAmt > 0 OR ExpiryDate <= NextPaymentDate THEN 0 
        ELSE ABS(BalanceAmt) 
    END,
    NextPaymentDate
FROM RecursiveRepayments
OPTION (MAXRECURSION 0);
