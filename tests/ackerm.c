#include <stdio.h>

// Codigo utilizado para testear el desempeño contra la maccina.

int ack(int m, int n)
{
    if (m == 0){
        return n+1;
    }
    else if((n == 0)){
        return ack(m-1, 1);
    }
    return ack(m-1, ack(m, n-1));
    
}
 
int main(){
    int A;
    A = ack(3, 11);
    printf("%d", A);
    return 0;
}